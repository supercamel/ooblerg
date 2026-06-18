# Vendor Overlay

Files in this overlay are copied into the extracted WebKitGTK source before
the WebKitGTKWin patch series is applied.

`Source/WTF/wtf/win` and `Source/WTF/wtf/text/win` were copied unchanged from
upstream WebKit tag `webkitgtk-2.52.3` (`b36308e46a8eb10cc17dc28e6f6779f8d19069fb`).
Ubuntu's `webkit2gtk` source package omits these Windows WTF backend files, but
the WebKitGTKWin port needs them when targeting MinGW.
