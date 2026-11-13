import QtQuick 2.5
import CustomElements 1.0
import "../../CustomBasics"
import "../../CustomControls"

BlockBase {
    id: root
    width: 100*dp
    height: 60*dp

    StretchColumn {
        anchors.fill: parent

        BlockRow {
            InputNode {
                id: gainInput
                node: block.node("gainNode")
                suggestions: ["Slider", "sACN In"]
            }
            StretchText {
                hAlign: Text.AlignHCenter
                // gain as 0...255; "In" when the gain comes from the connected input:
                text: gainInput.node.isConnected
                      ? "Gain: In"
                      : "Gain: " + Math.round(block.attr("gain").val * 255)
            }
            AttributeDotSlider {
                implicitWidth: 0  // fixed
                width: 30*dp
                attr: block.attr("gain")
                enabled: !gainInput.node.isConnected
                opacity: enabled ? 1 : 0.3
            }
        }

        DragArea {
            text: "Gain"
            InputNode {
                node: block.node("inputNode")
                suggestions: ["Slider", "Audio Level"]
            }
            OutputNode {
                node: block.node("outputNode")
                suggestions: ["Eos Channel", "Dimmer"]
            }
        }
    }
}
