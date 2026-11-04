#include "MacChannelInput.h"

#include <QDebug>
#include <QMetaObject>

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>


// ------------------------------------------------------------------------------------
// CoreAudio helpers
// ------------------------------------------------------------------------------------

static QString cfToQString(CFStringRef s) {
    if (!s) return QString();
    const CFIndex len = CFStringGetLength(s);
    std::vector<UniChar> buf(static_cast<size_t>(len));
    CFStringGetCharacters(s, CFRangeMake(0, len), buf.data());
    return QString(reinterpret_cast<const QChar*>(buf.data()), int(len));
}

static std::vector<AudioObjectID> allDevices() {
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDevices,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr) return {};
    std::vector<AudioObjectID> devices(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, devices.data()) != noErr) return {};
    return devices;
}

static int countInputChannels(AudioObjectID device) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreamConfiguration,
                                        kAudioObjectPropertyScopeInput,
                                        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, nullptr, &size) != noErr || size == 0) return 0;
    std::vector<char> mem(size);
    AudioBufferList* list = reinterpret_cast<AudioBufferList*>(mem.data());
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, list) != noErr) return 0;
    int channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += int(list->mBuffers[i].mNumberChannels);
    return channels;
}

// Same name lookup as Qt's CoreAudio backend (kAudioObjectPropertyName, input scope)
static AudioObjectID findInputDevice(const QString& name) {
    for (AudioObjectID dev: allDevices()) {
        if (countInputChannels(dev) <= 0) continue;
        AudioObjectPropertyAddress addr = { kAudioObjectPropertyName,
                                            kAudioObjectPropertyScopeInput,
                                            kAudioObjectPropertyElementMain };
        CFStringRef cfName = nullptr;
        UInt32 size = sizeof(cfName);
        if (AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &cfName) != noErr || !cfName) continue;
        const QString devName = cfToQString(cfName);
        CFRelease(cfName);
        if (devName == name) return dev;
    }
    return kAudioObjectUnknown;
}

// The IOProc receives data in each stream's virtual format; we handle 32-bit float,
// which is what CoreAudio uses for practically all devices.
static bool inputStreamsAreFloat32(AudioObjectID device) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreams,
                                        kAudioObjectPropertyScopeInput,
                                        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, nullptr, &size) != noErr || size == 0) return false;
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, streams.data()) != noErr) return false;
    for (AudioStreamID s: streams) {
        AudioObjectPropertyAddress fAddr = { kAudioStreamPropertyVirtualFormat,
                                             kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain };
        AudioStreamBasicDescription f = {};
        UInt32 fSize = sizeof(f);
        if (AudioObjectGetPropertyData(s, &fAddr, 0, nullptr, &fSize, &f) != noErr) return false;
        if (f.mFormatID != kAudioFormatLinearPCM) return false;
        if (!(f.mFormatFlags & kAudioFormatFlagIsFloat) || f.mBitsPerChannel != 32) return false;
    }
    return true;
}

static double nominalSampleRate(AudioObjectID device) {
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyNominalSampleRate,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &rate) != noErr) return 0;
    return rate;
}


// ------------------------------------------------------------------------------------
// One shared capture (IOProc) per device, used by all its channel inputs
// ------------------------------------------------------------------------------------

struct DeviceCapture {
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID procID = nullptr;
    std::mutex mutex;
    std::vector<std::pair<MacChannelInput*, unsigned>> subscribers;  // input, channel
};

static std::map<AudioObjectID, std::unique_ptr<DeviceCapture>>& captures() {
    static std::map<AudioObjectID, std::unique_ptr<DeviceCapture>> s_captures;  // main thread only
    return s_captures;
}

static OSStatus captureIOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* inInputData,
                              const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* clientData) {
    DeviceCapture* cap = static_cast<DeviceCapture*>(clientData);
    if (!inInputData) return noErr;
    std::lock_guard<std::mutex> lock(cap->mutex);
    for (const auto& sub: cap->subscribers) {
        unsigned ch = sub.second;
        // find the buffer (= stream) that contains this channel:
        for (UInt32 b = 0; b < inInputData->mNumberBuffers; ++b) {
            const AudioBuffer& buf = inInputData->mBuffers[b];
            const unsigned n = buf.mNumberChannels;
            if (n == 0 || !buf.mData) continue;
            if (ch < n) {
                const unsigned frames = buf.mDataByteSize / (sizeof(float) * n);
                sub.first->pushSamples(static_cast<const float*>(buf.mData) + ch, frames, n);
                break;
            }
            ch -= n;
        }
    }
    return noErr;
}


// ------------------------------------------------------------------------------------
// MacChannelInput
// ------------------------------------------------------------------------------------

static const OSStatus kNoMoreInputData = 0x6E6D6964;  // 'nmid'

struct ConverterFill {
    const float* data;
    UInt32 frames;
};

static OSStatus converterInputProc(AudioConverterRef, UInt32* ioNumberDataPackets, AudioBufferList* ioData,
                                   AudioStreamPacketDescription**, void* userData) {
    ConverterFill* fill = static_cast<ConverterFill*>(userData);
    if (fill->frames == 0) {
        *ioNumberDataPackets = 0;
        return kNoMoreInputData;  // "no more input for now", converter keeps its state
    }
    const UInt32 n = std::min(*ioNumberDataPackets, fill->frames);
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mDataByteSize = n * sizeof(float);
    ioData->mBuffers[0].mData = const_cast<float*>(fill->data);
    fill->data += n;
    fill->frames -= n;
    *ioNumberDataPackets = n;
    return noErr;
}

int MacChannelInput::inputChannelCount(const QString& deviceName) {
    const AudioObjectID dev = findInputDevice(deviceName);
    if (dev == kAudioObjectUnknown) return 0;
    return countInputChannels(dev);
}

MacChannelInput::MacChannelInput(QObject* parent)
    : QIODevice(parent)
{
}

MacChannelInput* MacChannelInput::create(const QString& deviceName, int channel, int sampleRate, QObject* parent) {
    const AudioObjectID dev = findInputDevice(deviceName);
    if (dev == kAudioObjectUnknown) {
        qInfo() << "MacChannelInput: device not found, using Qt audio input:" << deviceName;
        return nullptr;
    }
    if (channel < 0 || channel >= countInputChannels(dev)) return nullptr;
    if (!inputStreamsAreFloat32(dev)) {
        qInfo() << "MacChannelInput: device doesn't deliver float samples, using Qt audio input:" << deviceName;
        return nullptr;
    }
    const double deviceRate = nominalSampleRate(dev);
    if (deviceRate <= 0) return nullptr;

    // converter: mono float32 @ device rate -> mono int16 @ sampleRate
    AudioStreamBasicDescription in = {};
    in.mSampleRate = deviceRate;
    in.mFormatID = kAudioFormatLinearPCM;
    in.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    in.mBytesPerPacket = 4;
    in.mFramesPerPacket = 1;
    in.mBytesPerFrame = 4;
    in.mChannelsPerFrame = 1;
    in.mBitsPerChannel = 32;

    AudioStreamBasicDescription out = {};
    out.mSampleRate = sampleRate;
    out.mFormatID = kAudioFormatLinearPCM;
    out.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    out.mBytesPerPacket = 2;
    out.mFramesPerPacket = 1;
    out.mBytesPerFrame = 2;
    out.mChannelsPerFrame = 1;
    out.mBitsPerChannel = 16;

    AudioConverterRef converter = nullptr;
    if (AudioConverterNew(&in, &out, &converter) != noErr || !converter) {
        qWarning() << "MacChannelInput: AudioConverterNew failed";
        return nullptr;
    }

    MacChannelInput* input = new MacChannelInput(parent);
    input->m_channel = unsigned(channel);
    input->m_deviceRate = deviceRate;
    input->m_converter = converter;
    input->m_pending.reserve(size_t(deviceRate));

    // shared capture for this device:
    auto& map = captures();
    auto it = map.find(dev);
    if (it == map.end()) {
        std::unique_ptr<DeviceCapture> cap(new DeviceCapture);
        cap->device = dev;
        if (AudioDeviceCreateIOProcID(dev, captureIOProc, cap.get(), &cap->procID) != noErr) {
            qWarning() << "MacChannelInput: AudioDeviceCreateIOProcID failed";
            delete input;
            return nullptr;
        }
        it = map.emplace(dev, std::move(cap)).first;
    }
    DeviceCapture* cap = it->second.get();
    bool start = false;
    {
        std::lock_guard<std::mutex> lock(cap->mutex);
        start = cap->subscribers.empty();
        cap->subscribers.emplace_back(input, unsigned(channel));
    }
    input->m_capture = cap;
    if (start && AudioDeviceStart(dev, cap->procID) != noErr) {
        qWarning() << "MacChannelInput: AudioDeviceStart failed";
        delete input;  // unsubscribes and cleans up
        return nullptr;
    }

    input->open(QIODevice::ReadOnly);
    qInfo() << "MacChannelInput: capturing" << deviceName << "channel" << channel + 1
            << "at" << deviceRate << "Hz";
    return input;
}

MacChannelInput::~MacChannelInput() {
    if (m_capture) {
        bool last = false;
        {
            std::lock_guard<std::mutex> lock(m_capture->mutex);
            auto& subs = m_capture->subscribers;
            subs.erase(std::remove_if(subs.begin(), subs.end(),
                                      [this](const std::pair<MacChannelInput*, unsigned>& s) { return s.first == this; }),
                       subs.end());
            last = subs.empty();
        }
        // after unsubscribing, the IOProc doesn't touch this object anymore
        if (last) {
            const AudioObjectID dev = m_capture->device;
            AudioDeviceStop(dev, m_capture->procID);
            AudioDeviceDestroyIOProcID(dev, m_capture->procID);
            captures().erase(dev);
        }
        m_capture = nullptr;
    }
    if (m_converter) {
        AudioConverterDispose(static_cast<AudioConverterRef>(m_converter));
        m_converter = nullptr;
    }
}

void MacChannelInput::pushSamples(const float* data, unsigned frames, unsigned stride) {
    {
        std::lock_guard<std::mutex> lock(m_pendingMutex);
        // don't grow without limit if the main thread is blocked (keep max. ~2 s):
        const size_t maxPending = size_t(m_deviceRate * 2);
        if (m_pending.size() > maxPending) {
            m_pending.erase(m_pending.begin(), m_pending.begin() + long(m_pending.size() - maxPending / 2));
        }
        for (unsigned i = 0; i < frames; ++i) {
            m_pending.push_back(data[size_t(i) * stride]);
        }
    }
    if (!m_scheduled.exchange(true)) {
        QMetaObject::invokeMethod(this, [this]() { processPending(); }, Qt::QueuedConnection);
    }
}

void MacChannelInput::processPending() {
    m_scheduled = false;
    m_convertPrev.swap(m_convertIn);
    m_convertIn.clear();
    {
        std::lock_guard<std::mutex> lock(m_pendingMutex);
        m_convertIn.swap(m_pending);
    }
    if (m_convertIn.empty() || !m_converter) return;

    ConverterFill fill { m_convertIn.data(), UInt32(m_convertIn.size()) };
    std::vector<int16_t> outBuf(4096);
    const int bytesBefore = m_out.size();
    while (true) {
        UInt32 packets = UInt32(outBuf.size());
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = 1;
        abl.mBuffers[0].mDataByteSize = packets * sizeof(int16_t);
        abl.mBuffers[0].mData = outBuf.data();
        const OSStatus status = AudioConverterFillComplexBuffer(static_cast<AudioConverterRef>(m_converter),
                                                                converterInputProc, &fill, &packets, &abl, nullptr);
        if (packets > 0) {
            m_out.append(reinterpret_cast<const char*>(outBuf.data()), int(packets * sizeof(int16_t)));
        }
        if (status != noErr || packets == 0) break;  // kNoMoreInputData: all input consumed
    }
    // limit unread data (~2 s at 44.1 kHz):
    if (m_out.size() > 2 * 2 * 44100) m_out.remove(0, m_out.size() - 2 * 44100);

    if (m_out.size() > bytesBefore) emit readyRead();
}

qint64 MacChannelInput::bytesAvailable() const {
    return qint64(m_out.size()) + QIODevice::bytesAvailable();
}

qint64 MacChannelInput::readData(char* data, qint64 maxlen) {
    const qint64 n = std::min<qint64>(maxlen, m_out.size());
    if (n <= 0) return 0;
    memcpy(data, m_out.constData(), size_t(n));
    m_out.remove(0, int(n));
    return n;
}
