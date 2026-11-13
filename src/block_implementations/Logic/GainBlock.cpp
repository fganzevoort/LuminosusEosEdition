#include "GainBlock.h"

#include "core/Nodes.h"


GainBlock::GainBlock(MainController* controller, QString uid)
    : InOutBlock(controller, uid)
    , m_gain(this, "gain", 1.0, 0.0, 1.0)
{
    m_gainNode = createInputNode("gainNode");

    // the output has the size of the signal input, a single gain value applies to all pixels:
    m_outputNode->addNodeSharingRequestedSize(m_inputNode);

    connect(m_inputNode, SIGNAL(dataChanged()), this, SLOT(update()));
    connect(m_gainNode, SIGNAL(dataChanged()), this, SLOT(update()));
    connect(m_gainNode, SIGNAL(connectionChanged()), this, SLOT(update()));
    connect(&m_gain, SIGNAL(valueChanged()), this, SLOT(update()));
}

void GainBlock::update() {
    const ColorMatrix& input = m_inputNode->constData();
    RgbDataModifier out(m_outputNode);

    const bool gainFromNode = m_gainNode && m_gainNode->isConnected();
    const ColorMatrix* gainMatrix = gainFromNode ? &m_gainNode->constData() : nullptr;
    // gain per pixel only if the gain input has (at least) the size of the output:
    const bool gainPerPixel = gainMatrix && gainMatrix->width() >= out.width && gainMatrix->height() >= out.height
            && (gainMatrix->width() > 1 || gainMatrix->height() > 1);
    const double singleGain = gainMatrix ? gainMatrix->getValue() : double(m_gain);

    const int width = qMin(out.width, input.width());
    const int height = qMin(out.height, input.height());

    for (int x = 0; x < width; ++x) {
        for (int y = 0; y < height; ++y) {
            double gain = gainPerPixel ? gainMatrix->getHsvAt(x, y).v : singleGain;
            gain = limit(0.0, gain, 1.0);
            RGB col = input.getRgbAt(x, y);
            col.r *= gain;
            col.g *= gain;
            col.b *= gain;
            out.set(x, y, col);
        }
    }
}
