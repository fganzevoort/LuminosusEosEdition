#ifndef MACCHANNELINPUT_H
#define MACCHANNELINPUT_H

#include <QIODevice>
#include <QByteArray>
#include <QString>
#include <atomic>
#include <mutex>
#include <vector>

/**
 * macOS: delivers ONE channel of a CoreAudio input device as mono, signed 16-bit PCM
 * at the requested sample rate, through the normal QIODevice interface (readyRead / readAll).
 *
 * Why not QAudioInput: Qt 5's CoreAudio backend accepts at most 16 channels. For devices
 * with more channels (e.g. an Allen & Heath SQ with 32 USB channels) QAudioDeviceInfo::
 * nearestFormat() then falls back to 1 channel, so every "channel" analyser received
 * channel 1. This class reads the device directly (one shared CoreAudio IOProc per device,
 * no channel limit) and resamples with an AudioConverter (e.g. 96 kHz -> 44.1 kHz).
 */
class MacChannelInput : public QIODevice
{
public:
    /// Returns nullptr if the device can't be opened this way (caller falls back to QAudioInput).
    /// deviceName: name as reported by QAudioDeviceInfo::deviceName()
    /// channel: 0-based channel index across all input streams of the device
    static MacChannelInput* create(const QString& deviceName, int channel, int sampleRate, QObject* parent);

    /// Total number of input channels of the device (all streams), 0 if not found.
    static int inputChannelCount(const QString& deviceName);

    ~MacChannelInput() override;

    bool isSequential() const override { return true; }
    qint64 bytesAvailable() const override;

    // --- internal, called from the CoreAudio IO thread ---
    void pushSamples(const float* data, unsigned frames, unsigned stride);

protected:
    qint64 readData(char* data, qint64 maxlen) override;
    qint64 writeData(const char*, qint64) override { return -1; }

private:
    MacChannelInput(QObject* parent);
    void processPending();  // main thread: resample pending samples, emit readyRead()

    struct DeviceCapture* m_capture = nullptr;
    unsigned m_channel = 0;
    double m_deviceRate = 48000.0;
    void* m_converter = nullptr;  // AudioConverterRef

    std::mutex m_pendingMutex;
    std::vector<float> m_pending;      // filled by IO thread
    std::vector<float> m_convertIn;    // being converted (kept alive for AudioConverter)
    std::vector<float> m_convertPrev;  // previous input, kept alive one more round
    std::atomic<bool> m_scheduled { false };

    QByteArray m_out;  // converted 16-bit samples waiting to be read
};

#endif // MACCHANNELINPUT_H
