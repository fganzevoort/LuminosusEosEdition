#ifndef MACAUDIOPERMISSIONS_H
#define MACAUDIOPERMISSIONS_H

#include <QString>

/**
 * macOS-specific helpers to make audio input work on modern macOS (10.14 and later).
 *
 * - macEnsureMicrophoneAccess() asks the user for microphone / audio-input permission
 *   (TCC) before any QAudioInput is opened. Without this, Qt 5 opens the device but
 *   receives only silence, or the app is terminated by the system.
 *
 * - macCreateSystemAudioDevice() creates a private Core Audio aggregate device that
 *   contains a process tap of all audio played by other apps (QLab, Music, browsers...).
 *   It shows up in Luminosus as a normal stereo input device called "System Audio".
 *   Requires macOS 14.2 or later (14.4+ recommended); on older systems it does nothing.
 */

enum class MacMicPermission { Granted, Denied, Restricted, Unknown };

/// Blocks (while still processing UI events) until the user answered the permission
/// prompt. Returns immediately if permission was already decided.
MacMicPermission macEnsureMicrophoneAccess();

/// macOS 15+: performs a harmless local network operation (connecting a UDP socket to
/// a link-local IPv6 address, no traffic is sent) so the Local Network permission prompt
/// appears right at startup instead of silently dropping the first OSC / Art-Net packets.
/// Technique from Apple TN3179.
void macTriggerLocalNetworkAlert();

/// Returns true if the "System Audio" device was created.
bool macCreateSystemAudioDevice(QString* errorMessage = nullptr);

/// Destroys the aggregate device and tap created above (call on exit).
void macDestroySystemAudioDevice();

/// Name of the aggregate device as it appears in the input list.
QString macSystemAudioDeviceName();

#endif // MACAUDIOPERMISSIONS_H
