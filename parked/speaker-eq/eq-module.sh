# ═══════════════════════ module: eq ════════════════════════════════════════
# Installed as a native Omarchy speaker tuning rather than a loose filter-chain.
# That naming is not cosmetic: the shell hides the physical sink while a sink
# called omarchy_speaker_tuning fronts it, and excludes the tuning's own output
# from the application list -- so the stock path shows ONE output named for the
# speakers, where a hand-rolled chain shows the tuning and the hardware twice.
# It also makes the volume keys resolve through the filter to the real sink.
OMARCHY_TUNINGS="${OMARCHY_PATH:-/usr/share/omarchy}/default/audio/tunings"
EQ_TUNING_SRC="${REPO_DIR}/audio/tunings/imac18-3"
EQ_TUNING_DEST="${OMARCHY_TUNINGS}/imac18-3"
EQ_TUNING_KEEP="/usr/local/share/omarchy-imac5k/tunings/imac18-3"
EQ_TUNING_HOOK="/etc/pacman.d/hooks/imac-speaker-tuning.hook"
WP_NAMES_SRC="${REPO_DIR}/audio/wireplumber/51-imac-audio-names.conf"
WP_NAMES="${HOME}/.config/wireplumber/wireplumber.conf.d/51-imac-audio-names.conf"
mod_eq_title() { echo "Speaker tone EQ"; }
mod_eq_tier()  { echo safe; }
mod_eq_desc()  { echo "The codec does no DSP at all; macOS's warmth is entirely software EQ. Installs an Omarchy speaker tuning (bass shelf + lookahead limiter) and keeps it off the headphone jack."; }
mod_eq_detect() {
    local tuning=0 host=0
    [[ -f "${EQ_TUNING_DEST}/tuning.conf" ]] && tuning=1
    systemctl --user is-active omarchy-speaker-tuning.service &>/dev/null && host=1
    if (( tuning && host )); then echo applied
    elif (( tuning || host )); then echo partial
    else echo not-applied; fi
}
mod_eq_apply() {
    # Every Omarchy tuning ends in a lookahead limiter, which is an LV2 plugin;
    # omarchy-audio-tuning refuses to install without it.
    if [[ ! -e /usr/lib/lv2/lsp-plugins.lv2/limiter_stereo.ttl ]]; then
        say "installing the LV2 limiter the tuning needs"
        sudo pacman -S --needed --noconfirm lsp-plugins-lv2 || return 1
    fi
    [[ -f "${EQ_TUNING_SRC}/tuning.conf" ]] || { warn "tuning missing: ${EQ_TUNING_SRC}"; return 1; }
    say "installing the iMac18,3 tuning into ${EQ_TUNING_DEST}"
    sudo install -d -m755 "$EQ_TUNING_DEST" || return 1
    sudo install -m644 "${EQ_TUNING_SRC}/tuning.conf" "${EQ_TUNING_SRC}/filter-chain.conf" "$EQ_TUNING_DEST" || return 1
    # omarchy-settings owns that directory and an update replaces it, which
    # silently switches the EQ off. Keep a copy outside it and let pacman put
    # the tuning back after every omarchy-settings upgrade.
    sudo install -d -m755 "$EQ_TUNING_KEEP" || return 1
    sudo install -m644 "${EQ_TUNING_SRC}/tuning.conf" "${EQ_TUNING_SRC}/filter-chain.conf" "$EQ_TUNING_KEEP" || return 1
    sudo install -Dm644 "${REPO_DIR}/audio/pacman/imac-speaker-tuning.hook" "$EQ_TUNING_HOOK" || return 1

    # An earlier revision of this patch shipped the same curve as a loose
    # filter-chain fragment. Left in place it would run a second copy of the EQ
    # in series with the tuning.
    if [[ -f "$EQ_DEST" ]]; then
        say "removing the superseded standalone EQ fragment"
        rm -f "$EQ_DEST"
        systemctl --user disable --now filter-chain.service &>/dev/null
    fi

    omarchy-audio-tuning on || { warn "omarchy-audio-tuning refused — see the message above"; return 1; }

    # The codec publishes itself as its part number, "CS8409/CS42L83 Analog".
    say "installing readable device names"
    install -Dm644 "$WP_NAMES_SRC" "$WP_NAMES" || return 1
    systemctl --user restart wireplumber || true

    if omarchy-audio-tuning fronted-sink >/dev/null 2>&1; then
        say "one output, named iMac Audio — the bare codec is hidden behind it"
    else
        warn "the tuning sink is not fronting the hardware; the output list will still show both"
    fi
}
mod_eq_remove() {
    rm -f "$WP_NAMES"
    omarchy-audio-tuning off || true
    [[ -d "$EQ_TUNING_DEST" ]] && sudo rm -rf "$EQ_TUNING_DEST"
    sudo rm -rf "$EQ_TUNING_KEEP" "$EQ_TUNING_HOOK"
    say "tuning removed — output goes straight to the codec again"
}
