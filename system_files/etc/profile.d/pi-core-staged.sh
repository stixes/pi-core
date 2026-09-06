# Tell an interactive login that an update is waiting for a reboot.
#
# This is a profile.d script rather than a motd.d snippet on purpose: motd.d
# files are generated once at boot, and a deployment is staged long after that
# -- by `bootc upgrade` or by rpm-ostreed-automatic. A boot-time snippet would
# never mention it. console-login-helper-messages makes the same split for
# failed units.
#
# /run/ostree/staged-deployment exists exactly while a deployment is staged, so
# this costs one stat rather than a `bootc status` on every login.
# $- carries the shell's own flags; PS1 is not reliable here, because bash
# unsets it for non-interactive shells even when it is in the environment.
# This is the test console-login-helper-messages uses in the same situation.
case $- in
    *i*)
        if [ -e /run/ostree/staged-deployment ]; then
            printf '\033[1;33mAn update is staged.\033[0m Reboot to apply it:  sudo systemctl reboot\n\n'
        fi
        ;;
esac
