#include "SAcnInBlock.h"

#include "sacn/sacnlistener.h"
#include "utils.h"


SAcnInBlock::SAcnInBlock(MainController* controller, QString uid)
    : OneOutputBlock (controller, uid)
    , m_listener(nullptr)
    , m_universe(this, "universe", 1, 1, 63999)
    , m_channel(this, "channel", 1, 1, 512)
    , m_16bit(this, "16bit", false)
{
    updateListener();
    connect(&m_universe, &IntegerAttribute::valueChanged, this, &SAcnInBlock::updateListener);
}

void SAcnInBlock::onLevelsChanged() {
    if (m_listener.isNull()) return;
    // mergedLevel() is thread-safe (the listener runs in its own thread):
    int level = m_listener->mergedLevel(m_channel - 1);
    if (m_16bit && m_channel < 512) {
        int fine = qMax(0, m_listener->mergedLevel(m_channel));
        setValue(limit(0.0, (level + fine / 255.0) / 255.0, 1.0));
    } else {
        setValue(limit(0.0, level / 255.0, 1.0));
    }
}

void SAcnInBlock::updateListener() {
    if (!m_listener.isNull()) {
        disconnect(m_listener.data(), &sACNListener::levelsChanged, this, &SAcnInBlock::onLevelsChanged);
        m_listener.clear();
    }
    m_listener = sACNManager::getInstance()->getListener(m_universe);
    connect(m_listener.data(), &sACNListener::levelsChanged, this, &SAcnInBlock::onLevelsChanged);
    onLevelsChanged();
}
