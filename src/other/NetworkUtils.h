#ifndef NETWORKUTILS_H
#define NETWORKUTILS_H

#include <QList>
#include <QHostAddress>
#include <QNetworkInterface>

/**
 * Returns the directed broadcast address (e.g. 2.255.255.255, 10.0.0.255) of every
 * active, broadcast-capable IPv4 network interface (Ethernet, Wi-Fi, ...).
 *
 * Why: on macOS (and BSD) a datagram sent to the limited broadcast address
 * 255.255.255.255 leaves through ONE interface only (the one with the default route,
 * often Wi-Fi). With a separate lighting network on Ethernet, broadcasts such as
 * Eos OSC discovery or ArtNet would never reach that network. Sending to each
 * interface's own broadcast address reaches every connected network.
 *
 * Falls back to 255.255.255.255 if no suitable interface is found.
 */
inline QList<QHostAddress> allIPv4BroadcastAddresses() {
    QList<QHostAddress> result;
    for (const QNetworkInterface& iface: QNetworkInterface::allInterfaces()) {
        const auto flags = iface.flags();
        if (!(flags & QNetworkInterface::IsUp)) continue;
        if (!(flags & QNetworkInterface::IsRunning)) continue;
        if (!(flags & QNetworkInterface::CanBroadcast)) continue;
        if (flags & QNetworkInterface::IsLoopBack) continue;
        for (const QNetworkAddressEntry& entry: iface.addressEntries()) {
            if (entry.ip().protocol() != QAbstractSocket::IPv4Protocol) continue;
            const QHostAddress broadcast = entry.broadcast();
            if (broadcast.isNull()) continue;
            if (!result.contains(broadcast)) result.append(broadcast);
        }
    }
    if (result.isEmpty()) result.append(QHostAddress(QHostAddress::Broadcast));
    return result;
}

#endif // NETWORKUTILS_H
