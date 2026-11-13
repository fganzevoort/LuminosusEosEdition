#ifndef GAINBLOCK_H
#define GAINBLOCK_H

#include "core/block_data/InOutBlock.h"
#include "core/SmartAttribute.h"
#include "utils.h"

class NodeBase;


/**
 * @brief The GainBlock class scales (dampens) the value of its input by a gain value.
 *
 * Gain 255 (100%): the input passes unchanged.
 * Gain 0: the output is 0 (completely blocked).
 * In between the output is input * gain / 255.
 *
 * The gain comes from the "Gain" input node (any block: Slider, sACN In, Audio Level, ...).
 * If nothing is connected to it, the gain knob of the block is used.
 * A single gain value (e.g. from a Slider) is applied to every pixel of a matrix input;
 * a gain matrix of the same size is applied pixel by pixel.
 */
class GainBlock : public InOutBlock
{
    Q_OBJECT

public:

    static BlockInfo info() {
        static BlockInfo info;
        info.typeName = "Gain";
        info.nameInUi = "Gain";
        info.category << "General" << "Modify Value";
        info.helpText = "Dampens the incoming value depending on the gain value.\n\n"
                        "Gain 255 (100%): the value passes unchanged.\n"
                        "Gain 0: the value is completely blocked.\n"
                        "In between: output = input × gain / 255.\n\n"
                        "Connect any block to the upper 'Gain' input (e.g. a Slider or "
                        "sACN In block). If nothing is connected, the gain knob is used.";
        info.qmlFile = "qrc:/qml/Blocks/Logic/GainBlock.qml";
        info.complete<GainBlock>();
        return info;
    }

    explicit GainBlock(MainController* controller, QString uid);

public slots:
    virtual BlockInfo getBlockInfo() const override { return info(); }

private slots:
    void update();

protected:
    QPointer<NodeBase> m_gainNode;
    DoubleAttribute m_gain;  //!< used when nothing is connected to the gain input (0...1)
};

#endif // GAINBLOCK_H
