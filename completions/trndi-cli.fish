# Fish completion for trndi-cli.
# Install: copy to ~/.config/fish/completions/ or
# /usr/share/fish/vendor_completions.d/. `make install-completions` does the copy.
#
# Keep the option list in step with Usage in src/trndicli.pas.

complete -c trndi-cli -f
complete -c trndi-cli -s c -l check -d 'Print the reading, with the range in the exit code: 5 high, 6 low'
complete -c trndi-cli -s g -l graph -d 'Interactive TUI with a reading graph (F5 refreshes)'
complete -c trndi-cli -s s -l stats -d 'Summarise the last H hours (default 24, max 168)' -x
complete -c trndi-cli -l spark -d 'The last H hours as a sparkline (default 3, max 24)' -x
complete -c trndi-cli -l no-predict -d 'Graph mode: start without the forecast (F6 toggles)'
complete -c trndi-cli -l setup -d 'Settings window: backend, address, secret, unit, limits'
complete -c trndi-cli -s h -l help -d 'Show help'
