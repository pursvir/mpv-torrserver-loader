# mpv-torrserver-loader

MPV script which allows you to view and open torrents from a [TorrServer](https://github.com/YouROK/TorrServer) (Ctrl + T) along with autoloading external subtitles and audio for current video (which MPV still cannot do out of the box [^1] [^2]).

# Dependencies

This script requires **curl** to be installed in your system and available in PATH.

# Installation, setup

Copy Lua script into scripts folder and script-opts/torrserver_loader.conf into script-opts one. For more info about scripts installation check [this article](https://github.com/mpv-player/mpv/wiki/User-Scripts).

Also adjust TORRSERVER_SCHEME, TORRSERVERL_HOST and TORRSERVER_PORT variables in the script to your needs.

___

[^1]: https://github.com/mpv-player/mpv/issues/10523
[^2]: https://github.com/mpv-player/mpv/pull/12806
