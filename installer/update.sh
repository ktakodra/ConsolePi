#!/usr/bin/env bash

# ------------------------------------------------------------------------------------------------------------------------------------------------- #
# --                                                 ConsolePi Installation Script Stage 3                                                       -- #
# --  Wade Wells - Pack3tL0ss                                                                                                                    -- #
# --    report any issues/bugs on github or fork-fix and submit a PR                                                                             -- #
# --                                                                                                                                             -- #
# --  This script aims to automate the installation of ConsolePi.                                                                                -- #
# --  For more detail visit https://github.com/Pack3tL0ss/ConsolePi                                                                              -- #
# --                                                                                                                                             -- #
# --------------------------------------------------------------------------------------------------------------------------------------------------#

chg_password() {
    if [[ $iam == "pi" ]] && [ -e /run/sshwarn ]; then
        header
        echo "You are logged in as pi, and the default password has not been changed"
        prompt="Do You want to change the password for user pi"
        response=$(user_input_bool)
        if $response; then
            match=false
            while ! $match; do
                read -sep "Enter new password for user pi: " pass && echo
                read -sep "Re-Enter new password for user pi: " pass2 && echo
                [[ "${pass}" == "${pass2}" ]] && match=true || match=false
                ! $match && echo -e "ERROR: Passwords Do Not Match\n"
            done
            process="pi user password change"
            echo "pi:${pass}" | sudo chpasswd 2>> $log_file && logit "Success" ||
            ( logit "Failed to Change Password for pi user" "WARNING" &&
            echo -e "\n!!! There was an issue changing password.  Installation will continue, but continue to use existing password and update manually !!!" )
            unset pass && unset pass2 && unset process
        fi
    fi
}

set_hostname() {
    process="Change Hostname"
    hostn=$(cat /etc/hostname)
    if [[ "${hostn}" == "raspberrypi" ]]; then
        header
        valid_response=false

        while ! $valid_response; do
            # Display existing hostname
            read -ep "Current hostname $hostn. Do you want to configure a new hostname (y/n)?: " response
            response=${response,,}    # tolower
            ( [[ "$response" =~ ^(yes|y)$ ]] || [[ "$response" =~ ^(no|n)$ ]] ) && valid_response=true || valid_response=false
        done

        if [[ "$response" =~ ^(yes|y)$ ]]; then
            # Ask for new hostname $newhost
            ok_do_hostname=false
            while ! $ok_do_hostname; do
                read -ep "Enter new hostname: " newhost
                valid_response=false
                while ! $valid_response; do
                    printf "New hostname: ${_green}$newhost${_norm} Is this correect (y/n)?: " ; read -e response
                    response=${response,,}    # tolower
                    ( [[ "$response" =~ ^(yes|y)$ ]] || [[ "$response" =~ ^(no|n)$ ]] ) && valid_response=true || valid_response=false
                done
                [[ "$response" =~ ^(yes|y)$ ]] && ok_do_hostname=true || ok_do_hostname=false
            done

            # change hostname in /etc/hosts & /etc/hostname
            sed -i "s/$hostn/$newhost/g" /etc/hosts
            sed -i "s/$hostn\.$(grep -o "$hostn\.[0-9A-Za-z].*" /etc/hosts | cut -d. -f2-)/$newhost.$local_domain/g" /etc/hosts
            # change hostname via command
            hostname "$newhost" 1>&2 2>>/dev/null
            [ $? -gt 0 ] && logit "Error returned from hostname command" "WARNING"
            # add wlan hotspot IP to hostfile for DHCP connected clients to resolve this host
            wlan_hostname_exists=$(grep -c "$wlan_ip" /etc/hosts)
            [ $wlan_hostname_exists == 0 ] && echo "$wlan_ip       $newhost" >> /etc/hosts
            sed -i "s/$hostn/$newhost/g" /etc/hostname

            logit "New hostname set $newhost"
        fi
    else
        logit "Hostname ${hostn} is not default, assuming it is desired hostname"
    fi
    unset process
}

# -- set timezone --
set_timezone() {
    process="Configure ConsolePi TimeZone"
    cur_tz=$(date +"%Z")
    if [ $cur_tz == "GMT" ] || [ $cur_tz == "BST" ]; then
        header

        prompt="Current TimeZone $cur_tz. Do you want to configure the timezone"
        set_tz=$(user_input_bool)

        if $set_tz; then
            echo "Launching, standby..." && sudo dpkg-reconfigure tzdata 2>> $log_file && header && logit "Set new TimeZone to $(date +"%Z") Success" ||
                logit "FAILED to set new TimeZone" "WARNING"
        fi
    else
        logit "TimeZone ${cur_tz} not default (GMT) assuming set as desired."
    fi
    unset process
}

# -- if ipv6 is enabled present option to disable it --
disable_ipv6()  {
    process="Disable ipv6"
    prompt="Do you want to disable ipv6"
    dis_ipv6=$(user_input_bool)
    if $dis_ipv6; then
        file_diff_update "${src_dir}99-noipv6.conf" /etc/sysctl.d/99-noipv6.conf
    fi
    unset process
}

misc_imports(){
    # additional imports occur in related functions if import file exists
    process="Perform misc imports"
    if ! $upgrade; then
        # -- ssh authorized keys --
        found_path=$(get_staged_file_path "authorized_keys")
        [[ $found_path ]] && logit "pre-staged ssh authorized keys found - importing"
        if [[ $found_path ]]; then
            file_diff_update $found_path /root/.ssh/authorized_keys
            file_diff_update $found_path ${home_dir}.ssh/authorized_keys
                chown $iam:$iam ${home_dir}.ssh/authorized_keys
        fi

        # -- pre staged cloud creds --
        if $cloud && [[ -d ${stage_dir}.credentials ]]; then
            found_path=${stage_dir}.credentials
            mv $found_path/* "/etc/ConsolePi/cloud/${cloud_svc}/.credentials" 2>> $log_file &&
            logit "Found ${cloud_svc} credentials. Moving to /etc/ConsolePi/cloud/${cloud_svc}/.credentials"  ||
            logit "Error occurred moving your ${cloud_svc} credentials files" "WARNING"
        elif $cloud ; then
            logit "ConsolePi will be Authorized for ${cloud_svc} when you launch consolepi-menu"
            logit "raspbian-lite users refer to the GitHub for instructions on how to generate credential files off box"
        fi

        # -- custom overlay file for PoE hat (fan control) --
        found_path=$(get_staged_file_path "rpi-poe-overlay.dts")
        [[ $found_path ]] && logit "overlay file found creating dtbo"
        if [[ $found_path ]]; then
            sudo dtc -@ -I dts -O dtb -o /tmp/rpi-poe.dtbo $found_path >> $log_file 2>&1 &&
                overlay_success=true || overlay_success=false
                if $overlay_success; then
                    sudo mv /tmp/rpi-poe.dtbo /boot/overlays 2>> $log_file &&
                        logit "Successfully moved overlay file, will activate on boot" ||
                        logit "Failed to move overlay file"
                else
                    logit "Failed to create Overlay file from dts"
                fi
        fi

        # -- power.json --
        if $power && [[ -d ${stage_dir}power.json ]]; then
            found_path=${stage_dir}power.json
            mv $found_path $consolepi_dir 2>> $log_file &&
            logit "Found power control definitions @ ${found_path} Moving into $consolepi_dir"  ||
            logit "Error occurred moving your ${found_path} into $consolepi_dir " "WARNING"
        fi

    fi
    unset process
}

install_ser2net () {
    # To Do add check to see if already installed / update
    local process="Install ser2net via apt"
    logit "${process} - Starting"
    ser2net_ver=$(ser2net -v 2>> /dev/null | cut -d' ' -f3 && installed=true || installed=false)
    if [[ -z $ser2net_ver ]]; then
        apt-get -y install ser2net 1>/dev/null 2>> $log_file &&
            logit "ser2net install Success" ||
            logit "ser2net install Failed." "WARNING"
    else
        logit "Ser2Net ${ser2net_ver} already installed. No Action Taken re ser2net"
    fi

    do_ser2net=true
    if ! $upgrade; then
        found_path=$(get_staged_file_path "ser2net.conf")
        if [[ $found_path ]]; then
        cp $found_path "/etc" &&
            logit "Found ser2net.conf in ${found_path}.  Copying to /etc" ||
            logit "Error Copying your pre-staged ${found_path} file" "WARNING"
            do_ser2net=false
        fi
    fi

    if $do_ser2net && [[ ! $(head -1 /etc/ser2net.conf 2>>$log_File) =~ "ConsolePi" ]] ; then
        logit "Building ConsolePi Config for ser2net"
        [[ -f "/etc/ser2net.conf" ]]  && cp /etc/ser2net.conf $bak_dir  ||
            logit "Failed to Back up default ser2net to back dir" "WARNING"
        cp /etc/ConsolePi/src/ser2net.conf /etc/ 2>> $log_file ||
            logit "ser2net Failed to copy config file from ConsolePi src" "ERROR"
    fi

    systemctl daemon-reload ||
        logit "systemctl failed to reload daemons" "WARNING"

    logit "${process} - Complete"
}

dhcp_run_hook() {
    process="Configure dhcp.exit-hook"
    hook_file="/etc/ConsolePi/src/dhcpcd.exit-hook"
    logit "${process} - Starting"
    [[ -f /etc/dhcpcd.exit-hook ]] && exists=true || exists=false                      # find out if exit-hook file already exists
    if $exists; then
        is_there=`grep -c $hook_file  /etc/dhcpcd.exit-hook`  # find out if it's already pointing to ConsolePi script
        if [ $is_there -gt 0 ]; then
            logit "exit-hook already configured [File Found and Pointer exists]"  #exit-hook exists and line is already there
        else
            sudo sed -i '/.*\/etc\/ConsolePi\/.*/c\\/etc\/ConsolePi\/src\/dhcpcd.exit-hook "$@"' /etc/dhcpcd.exit-hook &&
            logit "Successfully Updated exit-hook Pointer" || logit "Failed to update exit-hook pointer" "ERROR"
        fi
    else
        sudo echo "$hook_file \"\$@\"" > "/etc/dhcpcd.exit-hook" || logit "Failed to create exit-hook script" "ERROR"
    fi

    # -- Make Sure exit-hook is executable --
    if [ -x /etc/dhcpcd.exit-hook ]; then
        logit "check executable: exit-hook file already executable"
    else
        sudo chmod +x /etc/dhcpcd.exit-hook 2>> $log_file || logit "Failed to make dhcpcd.exit-hook executable" "ERROR"
    fi
    logit "${process} - Complete"
    unset process
}

ConsolePi_cleanup() {
    # ConsolePi_cleanup is an init script that runs on startup / shutdown.  On startup it removes tmp files used by ConsolePi script to determine if the ip
    # address of an interface has changed (PB notifications only occur if there is a change). So notifications are always sent after a reboot.
    process="Deploy ConsolePi cleanup init Script"
        file_diff_update /etc/ConsolePi/src/systemd/ConsolePi_cleanup /etc/init.d/ConsolePi_cleanup
    unset process
}

#sub process used by install_ovpn
sub_check_vpn_config(){
    if [ -f /etc/openvpn/client/ConsolePi.ovpn ]; then
        if $push; then
            if [ $(sudo grep -c "script-security 2" /etc/openvpn/client/ConsolePi.ovpn) -eq 0 ]; then
                sudo echo -e "#\n# run push script to send notification of successful VPN connection\nscript-security 2" 1>> /etc/openvpn/client/ConsolePi.ovpn 2>>$log_file &&
                logit "Enabled script-security 2 in ConsolePi.ovpn" || logit "Unable to Enable script-security 2 in ConsolePi.ovpn" "WARNING"
            fi
            if [ $(sudo grep -c 'up "/etc/ConsolePi' /etc/openvpn/client/ConsolePi.ovpn) -eq 0 ]; then
                sudo echo 'up "/etc/ConsolePi/src/dhcpcd.exit-hook OVPN' 1>> /etc/openvpn/client/ConsolePi.ovpn 2>>$log_file &&
                logit "Added Pointer to on-up script in ConsolePi.ovpn" || logit "Failed to Add Pointer to on-up script in ConsolePi.ovpn" "WARNING"
            else
                sudo sed -i '/up\s\"\/etc\/ConsolePi\/.*/c\up \"\/etc\/ConsolePi\/src\/dhcpcd.exit-hook OVPN\"' /etc/openvpn/client/ConsolePi.ovpn &&
                logit "Succesfully Verified/Updated ovpn up Pointer" || logit "Failed to update ovpn up pointer" "WARNING"
            fi
        fi
    fi
}

install_ovpn() {
    process="OpenVPN"
    ! $upgrade && logit "Install OpenVPN" || logit "Verify OpenVPN is installed"
    ovpn_ver=$(openvpn --version 2>/dev/null| head -1 | awk '{print $2}')
    if [[ -z $ovpn_ver ]]; then
        sudo apt-get -y install openvpn 1>/dev/null 2>> $log_file && logit "OpenVPN installed Successfully" || logit "FAILED to install OpenVPN" "WARNING"
        if ! $ovpn_enable; then
            logit "You've chosen not to use the OpenVPN function.  Disabling OpenVPN. Package will remain installed. '/lib/systemd/systemd-sysv-install enable openvpn' to enable"
            /lib/systemd/systemd-sysv-install disable openvpn 1>/dev/null 2>> $log_file && logit "OpenVPN Disabled" || logit "FAILED to disable OpenVPN" "WARNING"
        else
            /lib/systemd/systemd-sysv-install enable openvpn 1>/dev/null 2>> $log_file && logit "OpenVPN Enabled" || logit "FAILED to enable OpenVPN" "WARNING"
        fi
    else
        logit "OpenVPN ${ovpn_ver} Already Installed/Current"
    fi

    if [ -f /etc/openvpn/client/ConsolePi.ovpn ]; then
        logit "Retaining existing ConsolePi.ovpn"
        $push && sub_check_vpn_config
    else
        found_path=$(get_staged_file_path "ConsolePi.ovpn")
        if [[ $found_path ]]; then
            cp $found_path "/etc/openvpn/client" &&
                logit "Found ${found_path}.  Copying to /etc/openvpn/client" ||
                logit "Error occurred Copying your ovpn config" "WARNING"
            $push && [ -f /etc/openvpn/client/ConsolePi.ovpn ] && sub_check_vpn_config
        else
            [[ ! -f "/etc/openvpn/client/ConsolePi.ovpn.example" ]] && sudo cp "${src_dir}ConsolePi.ovpn.example" "/etc/openvpn/client" ||
                logit "Retaining existing ConsolePi.ovpn.example file. See src dir for original example file."
        fi
    fi

    if [ -f /etc/openvpn/client/ovpn_credentials ]; then
        logit "Retaining existing openvpn credentials"
    else
        found_path=$(get_staged_file_path "ovpn_credentials")
        if [[ $found_path ]]; then
            mv $found_path "/etc/openvpn/client" &&
            logit "Found ovpn_credentials ${found_path}. Moving to /etc/openvpn/client"  ||
            logit "Error occurred moving your ovpn_credentials file" "WARNING"
        else
            [[ ! -f "/etc/openvpn/client/ovpn_credentials" ]] && cp "${src_dir}ovpn_credentials" "/etc/openvpn/client" ||
                logit "Retaining existing ovpn_credentials file. See src dir for original example file."
        fi
    fi

    sudo chmod 600 /etc/openvpn/client/* 1>/dev/null 2>> $log_file || logit "Failed chmod 600 openvpn client files" "WARNING"
    unset process
}

ovpn_graceful_shutdown() {
    process="OpenVPN Graceful Shutdown"
    systemd_diff_update "ovpn-graceful-shutdown"
    unset process
}

install_autohotspotn () {
    process="AutoHotSpotN"
    logit "Install/Update AutoHotSpotN"

    systemd_diff_update autohotspot

    logit "Installing hostapd via apt."
    if ! $(which hostapd >/dev/null); then
        apt-get -y install hostapd 1>/dev/null 2>> $log_file &&
            logit "hostapd install Success" ||
            logit "hostapd install Failed" "WARNING"
    else
        hostapd_ver=$(hostapd -v 2>&1| head -1| awk '{print $2}')
        logit "hostapd ${hostapd_ver} already installed"
    fi

    logit "Installing dnsmasq via apt."
    dnsmasq_ver=$(dnsmasq -v 2>/dev/null | head -1 | awk '{print $3}')
    if [[ -z $dnsmasq_ver ]]; then
        apt-get -y install dnsmasq 1>/dev/null 2>> $log_file &&
            logit "dnsmasq install Success" ||
            logit "dnsmasq install Failed" "WARNING"
    else
        logit "dnsmasq v${dnsmasq_ver} already installed"
    fi

    [[ -f ${override_dir}/hostapd.service ]] && hostapd_override=true || hostapd_override=false
    [[ -f ${override_dir}/dnsmasq.service ]] && dnsmasq_override=true || dnsmasq_override=false
    if ! $hostapd_override ; then
        logit "disabling hostapd (handled by AutoHotSpotN)."
        sudo systemctl unmask hostapd.service 1>/dev/null 2>> $log_file &&
            logit "Verified hostapd.service is unmasked" ||
                logit "failed to unmask hostapd.service" "WARNING"
        sudo /lib/systemd/systemd-sysv-install disable hostapd 1>/dev/null 2>> $log_file &&
            logit "hostapd autostart disabled Successfully" ||
                logit "An error occurred disabling hostapd autostart - verify after install" "WARNING"
    else
        logit "skipped hostapd disable - hostapd.service is overriden"
    fi

    if ! $dnsmasq_override ; then
        sudo /lib/systemd/systemd-sysv-install disable dnsmasq 1>/dev/null 2>> $log_file &&
            logit "dnsmasq on wlan interface autostart disabled Successfully" ||
                logit "An error occurred disabling dnsmasq (for wlan0) autostart - verify after install" "WARNING"
    else
        logit "skipped dnsmasq on wlan interface disable - dnsmasq.service is overriden"
    fi

    logit "Create/Configure hostapd.conf"
    convert_template hostapd.conf /etc/hostapd/hostapd.conf wlan_ssid=${wlan_ssid} wlan_psk=${wlan_psk} wlan_country=${wlan_country}
    sudo chmod +r /etc/hostapd/hostapd.conf 2>> $log_file || logit "Failed to make hostapd.conf readable - verify after install" "WARNING"

    file_diff_update ${src_dir}hostapd /etc/default/hostapd
    file_diff_update ${src_dir}interfaces /etc/network/interfaces

    # update hosts file based on supplied variables - this comes into play for devices connected to hotspot (dnsmasq will be able to resolve hostname to wlan IP)
    if [ -z $local_domain ]; then
        convert_template hosts /etc/hosts wlan_ip=${wlan_ip} hostname=$(head -1 /etc/hostname)
    else
        convert_template hosts /etc/hosts wlan_ip=${wlan_ip} hostname=$(head -1 /etc/hostname) domain=${local_domain}
    fi

    logit "Verify iw is installed on system."
    which iw >/dev/null 2>&1 && iw_ver=$(iw --version 2>/dev/null | awk '{print $3}') || iw_ver=0
    if [ $iw_ver == 0 ]; then
        logit "iw not found, Installing iw via apt."
        ( sudo apt-get -y install iw 1>/dev/null 2>> $log_file && logit "iw installed Successfully" ) ||
            logit "FAILED to install iw" "WARNING"
    else
        logit "iw $iw_ver already installed/current."
    fi

    # TODO place update in sysctl.d same as disbale ipv6
    logit "Enable IP-forwarding (/etc/sysctl.conf)"
    if $(! grep -q net.ipv4.ip_forward=1 /etc/sysctl.conf); then
    sed -i '/^#net\.ipv4\.ip_forward=1/s/^#//g' /etc/sysctl.conf 1>/dev/null 2>> $log_file && logit "Enable IP-forwarding - Success" ||
        logit "FAILED to enable IP-forwarding verify /etc/sysctl.conf 'net.ipv4.ip_forward=1'" "WARNING"
    else
        logit "ip forwarding already enabled"
    fi

    logit "${process} Complete"
    unset process
}

disable_autohotspot() {
    local process="Verify Auto HotSpot is disabled"
    systemctl is-active autohotspot >/dev/null 2>&1 && systemctl stop autohotspot >/dev/null 2>>$log_file ; rc=$?
    systemctl is-enabled autohotspot >/dev/null 2>&1 && systemctl disable autohotspot >/dev/null 2>>$log_file ; rc=$?
    [[ $rc -eq 0 ]] && logit "Success Auto HotSpot Service is Disabled" || logit "Error Disabling Auto HotSpot Service"
}

gen_dnsmasq_conf () {
    process="Configure dnsmasq"
    logit "Generating Files for dnsmasq."
    convert_template dnsmasq.conf /etc/dnsmasq.conf wlan_dhcp_start=${wlan_dhcp_start} wlan_dhcp_end=${wlan_dhcp_end}
    unset process
}

dhcpcd_conf () {
    process="dhcpcd.conf"
    logit "configure dhcp client and static fallback"
    convert_template dhcpcd.conf /etc/dhcpcd.conf wlan_ip=${wlan_ip}
    unset process
}

do_blue_config() {
    process="Bluetooth Console"
    logit "${process} Starting"
    ## Some Sections of the bluetooth configuration from https://hacks.mozilla.org/2017/02/headless-raspberry-pi-configuration-over-bluetooth/
    file_diff_update ${src_dir}systemd/bluetooth.service /lib/systemd/system/bluetooth.service

    # create /etc/systemd/system/rfcomm.service to enable
    # the Bluetooth serial port from systemctl
    systemd_diff_update rfcomm

    # enable the new rfcomm service
    do_systemd_enable_load_start rfcomm

    # add blue user and set to launch menu on login
    if $(! grep -q ^blue:.* /etc/passwd); then
        echo -e 'ConsoleP1!!\nConsoleP1!!\n' | sudo adduser --gecos "" blue 1>/dev/null 2>> $log_file &&
        logit "BlueTooth User created" ||
        logit "FAILED to create Bluetooth user" "WARNING"
    else
        logit "BlueTooth User already exists"
    fi

    # add blue user to dialout group so they can access /dev/ttyUSB_ devices
    #   and to consolepi group so they can access logs and data files for ConsolePi
    for group in dialout consolepi; do
        if [[ ! $(groups blue | grep -o $group) ]]; then
        sudo usermod -a -G $group blue 2>> $log_file && logit "BlueTooth User added to ${group} group" ||
            logit "FAILED to add Bluetooth user to ${group} group" "WARNING"
        else
            logit "BlueTooth User already in ${group} group"
        fi
    done

    # Give Blue user limited sudo rights to consolepi-commands
    if [ ! -f /etc/sudoers.d/010_blue-consolepi ]; then
        echo 'blue ALL=(ALL) NOPASSWD: /etc/ConsolePi/src/*' > /etc/sudoers.d/010_blue-consolepi &&
        logit "BlueTooth User given sudo rights for consolepi-commands" ||
        logit "FAILED to give Bluetooth user limited sudo rights" "WARNING"
    fi

    # Remove old blue user default tty cols/rows
    grep -q stty /home/blue/.bashrc &&
        sed -i 's/^stty rows 70 cols 150//g' /home/blue/.bashrc &&
        logit "blue user tty row col configuration removed - Success"

    # Configure blue user to auto-launch consolepi-menu on login (blue user is automatically logged in when connection via bluetooth is established)
    if [[ ! $(sudo grep consolepi-menu /home/blue/.bashrc) ]]; then
        sudo echo /etc/ConsolePi/src/consolepi-menu.sh | sudo tee -a /home/blue/.bashrc > /dev/null &&
            logit "BlueTooth User Configured to launch menu on Login" ||
            logit "FAILED to enable menu on login for BlueTooth User" "WARNING"
    else
        sudo sed -i 's/^consolepi-menu/\/etc\/ConsolePi\/src\/consolepi-menu.sh/' /home/blue/.bashrc &&
            logit "blue user configured to launch menu on Login" ||
            logit "blue user autolaunch bashrc error" "WARNING"
    fi

    # Configure blue user alias for consolepi-menu command (overriding the symlink to the full menu with cloud support)
    # TODO change this to use .bash_login or .bash_profile bashrc works lacking those files, more appropriate to use .profile over .bashrc anyway
    if [[ ! $(sudo grep "alias consolepi-menu" /home/blue/.bashrc) ]]; then
        sudo echo alias consolepi-menu=\"/etc/ConsolePi/src/consolepi-menu.sh\" | sudo tee -a /home/blue/.bashrc > /dev/null &&
            logit "BlueTooth User consolepi-menu alias Updated to use \"lite\" menu" ||
            logit "FAILED to update BlueTooth User consolepi-menu alias" "WARNING"
    else
        logit "blue user consolepi-menu alias already configured"
    fi

    # Install picocom
    if [[ $(picocom --help 2>/dev/null | head -1) ]]; then
        logit "$(picocom --help 2>/dev/null | head -1) is already installed"
    else
        logit "Installing picocom"
        sudo apt-get -y install picocom 1>/dev/null 2>> $log_file && logit "Install picocom Success" ||
                logit "FAILED to Install picocom" "WARNING"
    fi

    logit "${process} Complete"
    unset process
}

get_utils() {
    if [ -f "${consolepi_dir}installer/utilities.sh" ]; then
        . "${consolepi_dir}installer/utilities.sh"
    else
        echo "FATAL ERROR utilities.sh not found exiting"
        exit 1
    fi
}

do_resize () {
    # Install xterm cp the binary into consolepi-commands directory (which is in path) then remove xterm
    process="xterm ~ resize"
    if [ ! -f ${src_dir}consolepi-commands/resize ]; then
        # util_main xterm -I -p "xterm | resize"
        cmd_list=("-apt-install" "xterm" "--pretty=${process}" \
                  '-s' "export rsz_loc=\$(which resize)" \
                  "-stop" "-nostart" "-p" "Copy resize binary from xterm" "-f" "Unable to find resize binary after xterm install" \
                      "[ ! -z \$rsz_loc ] && sudo cp \$(which resize) ${src_dir}consolepi-commands/resize" \
                  "-l" "xterm will now be removed as we only installed it to get resize" \
                  "-apt-purge" "xterm"
                )
        process_cmds "${cmd_list[@]}"
    else
        logit "resize utility already present"
    fi
    unset process
}

# Create or Update ConsolePi API startup service (systemd)
do_consolepi_api() {
    process="ConsolePi API (systemd)"
    if [ $py3ver -ge 6 ] ; then
        systemd_diff_update consolepi-api
    else
        ! $upgrade && systemd_diff_update consolepi-api-flask
        logit "A newer version of the ConsolePi API is available but it requires Python>=3.6 ($(python3 -V) is installed) keeping existing API" "WARNING"
    fi
    unset process
}

# Create or Update ConsolePi mdns startup service (systemd)
do_consolepi_mdns() {
    process="ConsolePi mDNS (systemd)"
    systemd_diff_update consolepi-mdnsreg
    systemd_diff_update consolepi-mdnsbrowse
    for d in 'avahi-daemon.socket' 'avahi-daemon.service' ; do
        _error=false
        if ! systemctl status "$d" | grep -q disabled ; then
            [[ "$d" =~ "socket" ]] && logit "disabling ${d%.*} ConsolePi has it's own mdns daemon"
            systemctl stop "$d" >/dev/null 2>&1 || _error=true
            systemctl disable "$d" 2>/dev/null || _error=true
            $_error && logit "Error occured: stop - disable $d Check daemon status" "warning"
        fi
    done
    unset process
}

# Configure ConsolePi with the SSIDs it will attempt to connect to as client prior to falling back to hotspot
get_known_ssids() {
    process="Get Known SSIDs"
    logit "${process} Started"
    header
    if [ -f $wpa_supplicant_file ] && [[ $(cat $wpa_supplicant_file|grep -c network=) > 0 ]] ; then
        echo
        echo "----------------------------------------------------------------------------------------------"
        echo "wpa_supplicant.conf already exists with the following configuration"
        echo "----------------------------------------------------------------------------------------------"
        cat $wpa_supplicant_file
        echo "----------------------------------------------------------------------------------------------"
        word=" additional"
    else
        # if wpa_supplicant.conf exist in script dir cp it to ConsolePi image.
        # if EAP-TLS SSID is configured in wpa_supplicant extract EAP-TLS cert details and cp certs (not a loop only good to pre-configure 1)
        #   certs should be in user home dir, 'cert' subdir, 'ConsolePi_stage/cert, subdir cert_names are extracted from the wpa_supplicant.conf file found in script dir
        found_path=$(get_staged_file_path "wpa_supplicant.conf")
        if [[ -f $found_path ]]; then
            logit "Found stage file ${found_path} Applying"
            # ToDo compare the files ask user if they want to import if they dont match
            [[ -f $wpa_supplicant_file ]] && sudo cp $wpa_supplicant_file $bak_dir
            sudo mv $found_path $wpa_supplicant_file
            client_cert=$(grep client_cert= $found_path | cut -d'"' -f2| cut -d'"' -f1)
            if [[ ! -z $client_cert ]]; then
                cert_path=${client_cert%/*}
                ca_cert=$(grep ca_cert= $found_path | cut -d'"' -f2| cut -d'"' -f1)
                private_key=$(grep private_key= $found_path | cut -d'"' -f2| cut -d'"' -f1)
                if [[ -d /home/${iam}/cert ]]; then
                    cd /home/$iam/cert     # if user home contains cert subdir look there for certs - otherwise look in stage subdir
                elif [[ -d ${stage_dir}cert ]]; then
                    cd ${stage_dir}cert
                fi

                [[ ! -d $cert_path ]] && sudo mkdir -p "${cert_path}"
                [[ -f ${client_cert##*/} ]] && sudo cp ${client_cert##*/} "${cert_path}/${client_cert##*/}"
                [[ -f ${ca_cert##*/} ]] && sudo cp ${ca_cert##*/} "${cert_path}/${ca_cert##*/}"
                [[ -f ${private_key##*/} ]] && sudo cp ${private_key##*/} "${cert_path}/${private_key##*/}"
                cd "${cur_dir}"
            fi

            if [ -f $wpa_supplicant_file ] && [[ $(cat $wpa_supplicant_file|grep -c network=) > 0 ]] ; then
                echo
                echo "----------------------------------------------------------------------------------------------"
                echo "wpa_supplicant.conf was imported with the following configuration"
                echo "----------------------------------------------------------------------------------------------"
                cat $wpa_supplicant_file
                echo "----------------------------------------------------------------------------------------------"
                word=" additional"
            fi
        fi
    fi

    $hotspot && echo -e "\nConsolePi will attempt to connect to configured SSIDs prior to going into HotSpot mode.\n"
    prompt="Do You want to configure${word} WLAN SSIDs"
    user_input false "${prompt}"
    continue=$result

    if $continue; then
        if [ -f ${consolepi_dir}src/consolepi-addssids.sh ]; then
            . ${consolepi_dir}src/consolepi-addssids.sh
            known_ssid_init
            known_ssid_main
            mv $wpa_supplicant_file $bak_dir 1>/dev/null 2>> $log_file ||
                logit "Failed to backup existing file to originals dir" "WARNING"
            mv "$wpa_temp_file" "$wpa_supplicant_file" 1>/dev/null 2>> $log_file ||
                logit "Failed to move collected ssids to wpa_supplicant.conf Verify Manually" "WARNING"
        else
            logit "SSID collection script not found in ConsolePi src dir" "WARNING"
        fi
    else
        logit "User chose not to configure SSIDs via script.  You can run consolepi-addssids to invoke script after install"
    fi
    logit "${process} Complete"
    unset process
}

misc_stuff() {
    if [ ${wlan_country^^} == "US" ]; then
        process="Set Keyboard Layout"
        logit "${process} - Starting"
        sudo sed -i "s/gb/${wlan_country,,}/g" /etc/default/keyboard && logit "KeyBoard Layout changed to ${wlan_country,,}"
        logit "${process} - Success" || logit "${process} - Failed ~ verify contents of /etc/default/keyboard" "WARNING"
        unset process
    fi

    # -- Commented out for now because it apparently didn't work as expected, get occasional error msg
    # -- set locale -- # if US haven't verified others use same code as wlan_country
    # if [ ${wlan_country^^} == "US" ]; then
    #     process="Set locale"
    #     logit "${process} - Starting"
    #     sudo sed -i "s/GB/${wlan_country^^}/g" /etc/default/locale && logit "all locale vars changed to en_${wlan_country^^}.UTF-8" &&
    #     grep -q LANGUAGE= /etc/default/locale || echo LANGUAGE=en_${wlan_country^^}.UTF-8 >> /etc/default/locale
    #     grep -q LC_ALL= /etc/default/locale || echo LC_ALL=en_${wlan_country^^}.UTF-8 >> /etc/default/locale
    #     ! $(grep -q GB /etc/default/locale) && grep -q LANGUAGE= /etc/default/locale && grep -q LC_ALL= /etc/default/locale &&
    #         logit "${process} - Success" || logit "${process} - Failed ~ verify contents of /etc/default/locale" "WARNING"
    #     unset process
    # fi
}

get_serial_udev() {
    process="Predictable Console Ports"
    logit "${process} Starting"
    header

    # -- if pre-stage file provided during install enable it --
    if ! $upgrade; then
        found_path=$(get_staged_file_path "10-ConsolePi.rules")
        if [[ $found_path ]]; then
            logit "udev rules file found ${found_path} enabling provided udev rules"
            if [ -f /etc/udev/rules.d/10-ConsolePi.rules ]; then
                file_diff_update $found_path /etc/udev/rules.d
            else
                sudo cp $found_path /etc/udev/rules.d
                sudo udevadm control --reload-rules && sudo udevadm trigger
            fi
        fi
    fi

    echo
    echo -e "--------------------------------------------- \033[1;32mPredictable Console ports$*\033[m ---------------------------------------------"
    echo "-                                                                                                                   -"
    echo "- Predictable Console ports allow you to configure ConsolePi so that each time you plug-in a specific adapter it    -"
    echo "- will have the same name in consolepi-menu and will be reachable via the same TELNET port.                         -"
    echo "-                                                                                                                   -"
    echo "- This is useful if you plan to use multiple adapters/devices, or if you are using a multi-port pig-tail adapter.   -"
    echo '- Also useful if this is being used as a stationary solution.  So you can name the adaper "NASHDC-Rack12-SW3"       -'
    echo "-   rather than have them show up as ttyUSB0.                                                                       -"
    echo "-                                                                                                                   -"
    echo "- The behavior if you do *not* define Predictable Console Ports is the adapters will use the root device names      -"
    echo "-   ttyUSB# or ttyACM# where the # starts with 0 and increments for each adapter of that type plugged in. The names -"
    echo "-   won't necessarily be consistent between reboots.                                                                -"
    echo "-                                                                                                                   -"
    echo "- Defining the ports with this utility is also how device specific serial settings are configured.  Otherwise       -"
    echo "-   they will use the default which is 96008N1                                                                      -"
    echo "-                                                                                                                   -"
    echo "- As of Dec 2019 This uses a new mechanism with added support for more challengine adapters:                        -"
    echo "-   * Multi-Port Serial Adapters, where the adpater presents a single serial # for all ports                        -"
    echo "-   * Super Lame cheap crappy adapters that don't burn a serial# to the adapter at all:  (CODED NOT TESTED YET)     -"
    echo "-     If you have one of these.  First Check online with the manufacturer of the chip used in the adapter to see    -"
    echo "-     if they have a utility to flash the EEPROM, some manufacturers do which would allow you to write a serial #   -"
    echo "-     For example if the adapter uses an FTDI chip (which I reccomend) they have a utility called FT_PROG           -"
    echo "-     Most FTDI based adapters have serial #s, I've only seen the lack of serial # on dev boards.                   -"
    echo "-     ---- If you're interested I reccomend adapters that use FTDI chips. ----                                      -"
    echo "-                                                                                                                   -"
    echo '-  !! suppport for adapters that lack serial ports is not tested at all, so I probably goofed someplace.            -'
    echo "-     I need to find a lame adapter to test                                                                         -"
    echo "-                                                                                                                   -"
    echo '-  This function can be called anytime from the shell via `consolepi-addconsole` and is available from              -'
    echo '-    `consolepi-menu` as the `rn` (rename) option.                                                                  -'
    echo "-                                                                                                                   -"
    echo "---------------------------------------------------------------------------------------------------------------------"
    echo
    echo "You need to have the serial adapters you want to map to specific telnet ports available"
    prompt="Would you like to configure predictable serial ports now"
    $upgrade && user_input false "${prompt}" || user_input true "${prompt}"
    if $result ; then
        if [ -f ${consolepi_dir}src/consolepi-commands/consolepi-menu ]; then
            sudo ${consolepi_dir}src/consolepi-commands/consolepi-menu dev rn  # TODO CHANGE BEFORE MERGE WITH MASTER
        else
            logit "ERROR consolepi-menu not found" "WARNING"
        fi
    fi
    logit "${process} Complete"
    unset process
}

# -- run custom post install script --
custom_post_install_script() {
    if ! $upgrade; then
        found_path=$(get_staged_file_path "ConsolePi_init.sh")
        if [[ $found_path ]]; then
            process="Run Custom Post-install script"
            logit "Post Install Script ${found_path} Found. Executing"
            sudo $found_path && logit "Post Install Script Complete No Errors" ||
                logit "Error Code returned by Post Install Script" "WARNING"
            unset process
        fi
    fi
}

# -- Display Post Install Message --
post_install_msg() {
    clear
    echo
    echo "*********************************************** Installation Complete ***************************************************"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mNext Steps/Info\033[m                                                                                                       *"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mCloud Sync:\033[m                                                                                                           *"
    echo "*   if you plan to use cloud sync.  You will need to do some setup on the Google side and Authorize ConsolePi           *"
    echo "*   refer to the GitHub for more details                                                                                *"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mOpenVPN:\033[m                                                                                                              *"
    echo "*   if you are using the Automatic VPN feature you should Configure the ConsolePi.ovpn and ovpn_credentials files in    *"
    echo "*   /etc/openvpn/client.  Then run 'consolepi-upgrade' which will add a few lines to the config to enable some          *"
    echo "*   ConsolePi functionality.  There is a .example file for reference as well.                                           *"
    echo "*     You should \"sudo chmod 600 <filename>\" both of the files for added security                                       *"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mser2net Usage:\033[m                                                                                                        *"
    echo "*   Serial Ports are available starting with telnet port 8001 (ttyUSB#) or 9001 (ttyACM#) incrementing with each        *"
    echo "*   adapter plugged in.  if you configured predictable ports for specific serial adapters those start with 7001.        *"
    echo "*   **OR** just launch the consolepi-menu for a menu w/ detected adapters (there is a rename option in the menu).       *"
    echo "*                                                                                                                       *"
    echo "*   The Console Server has a control port on telnet 7000 type \"help\" for a list of commands available                   *"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mBlueTooth:\033[m                                                                                                            *"
    echo "*   ConsolePi should be discoverable (after reboot if this is the initial installation).                                *"
    echo "*   - Configure bluetooth serial on your device and pair with ConsolePi                                                 *"
    echo "*   - On client device attach to the com port created after the step above was completed                                *"
    echo "*   - Once Connected the Console Menu will automatically launch allowing you to connect to any serial devices found     *"
    echo "*   NOTE: The Console Menu is available from any shell session (bluetooth or SSH) via the consolepi-menu command        *"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mLogging:\033[m                                                                                                              *"
    echo "*   The bulk of logging for ConsolePi ends up in /var/log/ConsolePi/consolepi.log                                       *"
    echo "*   The tags 'puship', 'puship-ovpn', 'autohotspotN' and 'dhcpcd' are of key interest in syslog                         *"
    echo "*   - openvpn logs are sent to /var/log/ConsolePi/ovpn.log you can tail this log to troubleshoot any issues with ovpn   *"
    echo "*   - pushbullet responses (json responses to curl cmd) are sent to /var/log/ConsolePi/push_response.log                *"
    echo "*   - An install log can be found in ${consolepi_dir}installer/install.log                                               *"
    echo "*                                                                                                                       *"
    echo -e "* \033[1;32mConsolePi Commands:\033[m                                                                                                   *"
    echo "*   **Refer to the GitHub for the most recent complete list**                                                           *"
    echo -e "*   - ${_cyan}consolepi-menu${_norm}: Launch Console Menu which will provide connection options for connected serial adapters           *"
    echo -e "*       if cloud config feature is enabled menu will also show adapters on reachable remote ConsolePis                  *"
    echo -e "*   - ${_cyan}consolepi-upgrade${_norm}: upgrade ConsolePi. - supported update method.                                                  *"
    echo -e "*   - ${_cyan}consolepi-extras${_norm}: Launch optional utilites installer (tftp, ansible, lldp, cockpit, speedtest...(Pi 4 only ))     *"
    echo -e "*   - ${_cyan}consolepi-addssids${_norm}: Add additional known ssids. same as doing sudo /etc/ConsolePi/ssids.sh                        *"
    echo -e "*   - ${_cyan}consolepi-addconsole${_norm}: Configure serial adapter to telnet port rules. same as doing sudo /etc/ConsolePi/udev.sh    *"
    echo -e "*   - ${_cyan}consolepi-killvpn${_norm}: Gracefully terminate openvpn tunnel if one is established                                      *"
    echo -e "*   - ${_cyan}consolepi-autohotspot${_norm}: Manually invoke AutoHotSpot function which will look for known SSIDs and connect if found  *"
    echo -e "*       then fall-back to HotSpot mode if not found or unable to connect.                                               *"
    echo -e "*   - ${_cyan}consolepi-testhotspot${_norm}: Disable/Enable the SSIDs ConsolePi tries to connect to before falling back to hotspot.     *"
    echo -e "*       Used to test hotspot function.  Script Toggles state if enabled it will disable and vice versa.                 *"
    echo -e "*   - ${_cyan}consolepi-bton${_norm}: Make BlueTooth Discoverable and Pairable - this is the default behavior on boot.                  *"
    echo -e "*   - ${_cyan}consolepi-btoff${_norm}: Disable BlueTooth Discoverability.  You can still connect if previously paired.                  *"
    echo -e "*   - ${_cyan}consolepi-details${_norm}: Refer to GitHub for usage, but in short dumps the data the ConsolePi would run with based      *"
    echo "*       on configuration, discovery, etc.  Dumps everything if no args,                                                 *"
    echo "*        valid args: adapters, interfaces, outlets, remotes, local, <hostname of remote>.  GitHub for more detail       *"
    echo "*                                                                                                                       *"
    echo "**ConsolePi Installation Script v${INSTALLER_VER}**************************************************************************************"
    # Display any warnings
    [ $warn_cnt -gt 0 ] && echo -e "\n${_red}---- warnings exist ----${_norm}" && grep warning $log_file && echo ''
    # Script Complete Prompt for reboot if first install
    if $upgrade; then
        echo -e "\nConsolePi Upgrade Complete, a Reboot may be required if config options where changed during upgrade\n"
    else
        echo
        prompt="A reboot is required, do you want to reboot now"
        go_reboot=$(user_input_bool)
        $go_reboot && sudo reboot || echo -e "\nConsolePi Install script Complete, Reboot is required"
    fi
}

update_main() {
    # -- install.sh does --
    # remove_first_boot
    # updatepi
    # pre_git_prep
    # gitConsolePi
    # -- config.sh does --
    # get_config
    # ! $bypass_verify && verify
    # while ! $input; do
    #     collect
    #     verify
    # done
    # update_config
    # update_config_overrides
    if ! $upgrade; then
        chg_password
        set_hostname
        set_timezone
        disable_ipv6
    fi
    misc_imports
    install_ser2net
    dhcp_run_hook
    ConsolePi_cleanup
    if $ovpn_enable; then
        install_ovpn
        ovpn_graceful_shutdown
    fi
    if $hotspot ; then
        install_autohotspotn
        gen_dnsmasq_conf
    else
        disable_autohotspot
    fi
    dhcpcd_conf
    do_blue_config
    do_consolepi_api
    do_consolepi_mdns
    ! $upgrade && misc_stuff
    do_resize
    if [ ! -z $skip_utils ] && $skip_utils ; then
        process="optional utilities installer"
        logit "utilities menu bypassed by config variable"
        unset process
    else
        get_utils
        util_main
    fi
    get_known_ssids
    get_serial_udev
    custom_post_install_script
    post_install_msg
}
