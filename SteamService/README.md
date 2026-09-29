# SceneHarbor Steam service

This directory is an isolated external-process copy of Mirage's SteamKit2
Workshop service. SceneHarbor communicates with it through newline-delimited
JSON over stdin/stdout; Steam credentials never pass through the video or
renderer processes.

The copied service remains GPL-3.0. The source and the applicable notices are
kept in this directory so a future public distribution can provide the
required corresponding source and license information. SteamKit2 is LGPL-2.1
and its notice is in `Licenses/SteamKit2-NOTICE.txt`.

Supported protocol areas include QR/password/Steam Guard login, refresh-token
session restoration, subscription/favorites queries, and resumable Workshop
content downloads. SceneHarbor will initially expose only login, download,
cancel, and local-library rescan; unrelated social actions remain unavailable
from the new UI.
