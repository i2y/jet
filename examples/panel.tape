# vhs tape -> panel.gif : one ACP agent, a supervised BEAM fleet behind it.
# Warm the model first (outside the tape), then:  vhs examples/panel.tape
Output panel.gif
Set Shell zsh
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 22
Set Theme "Catppuccin Mocha"

Hide
Type "setopt interactive_comments && clear"
Enter
Sleep 800ms
Show

Type "# one ACP agent -- a supervised BEAM fleet behind it (parallel, crash-isolated)"
Enter
Sleep 1200ms
Type "./examples/panel_demo.sh"
Enter
Wait+Screen@60s /--- done ---/
Sleep 3s
