#!/usr/bin/env bash
# Drive the Panel fleet agent over ACP with one prompt, rendered compactly.
# Used by examples/panel.tape to record panel.gif; runnable on its own too.
cd "$(dirname "$0")/.." || exit 1
exec env COMPACT=1 PROMPTS='["Should a startup rewrite its backend in a brand-new language?"]' \
  node examples/mock_acp_client.js \
  ./jet acp-serve acp_fleet_demo::Panel::review examples/acp_fleet_demo.jet
