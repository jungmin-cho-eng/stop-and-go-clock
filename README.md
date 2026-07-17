# Mondane Stop-and-Go Clock

A small, dependency-free Windows clock widget inspired by the stop-and-go railway-clock design. It uses a clean analog face, a fast sweep that reaches 12 in 59 seconds, and a one-second pause during which the minute hand eases smoothly to its next marker.

## Run

Double-click **ClockWidget.exe**. It is a single portable executable: you can copy that file to another Windows PC and run it without the accompanying source or launcher files. It uses the WPF components included with the Windows .NET Framework.

## Controls

- Drag the clock face or title bar to move the window.
- Click the diamond in the title bar to toggle always-on-top.
- Right-click anywhere for **Always on top**, **Start with Windows**, **Sync now**, and **Exit**.
- Double-click the title bar to toggle always-on-top.
- Press Escape or click × to close.

## Time synchronization

The widget contacts `ntp.kriss.re.kr` over NTP/UDP port 123 once per minute, when the second hand begins its one-second stop at 12. The small indicator between the center and six o'clock turns off during that stop, then glows bright green when the hand resumes if synchronization succeeded. It remains dim if the clock has not synced or the latest attempt failed. The measured offset applies only to the displayed time, so the app does not need administrator rights and does not alter the Windows system clock.

## Automatic startup

Enable **Start with Windows** from the right-click menu. This adds a value under the current user's `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` key. Disable the same menu item to remove it.
