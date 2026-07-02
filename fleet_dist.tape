Output fleet_dist.gif
Set Shell "bash"
Set FontSize 18
Set Width 1120
Set Height 360
Set Padding 26
Set Theme "Dracula"
Set TypingSpeed 32ms
Sleep 400ms
Type "(./jet -r fleet_dist::worker examples/fleet_dist.jet &)"
Enter
Sleep 3s
Type "./jet -r fleet_dist::run examples/fleet_dist.jet"
Enter
Sleep 12s
