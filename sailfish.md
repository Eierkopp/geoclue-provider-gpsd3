Here are a few details about how to integrate an external bluetooth GPS mouse with your Jolla.

Commands starting with `#` should be executed as user root, while commands behind `$` should be run as the logged in user (defaultuser/nemo)

1. Pair the device with your Jolla
2. Find out the bluetooth MAC

        # bluetoothctl devices
        Device 00:1C:88:06:07:CF Qstarz 1000XT
    
3. Find out the channel to be used:
    
        # sdptool browse 00:1C:88:06:07:CF
        Browsing 00:1C:88:06:07:CF ...
        Service Name: SPP slave
        Service RecHandle: 0x10000
        Service Class ID List:
           "Serial Port" (0x1101)
        Protocol Descriptor List:
           "L2CAP" (0x0100)
           "RFCOMM" (0x0003)
           Channel: 1

Here it's a serial device behind channel 1.
    
4. I didn't manage to use hciattach to connect the device, since CONFIG_BT_RFCOMM_TTY is not enabled in the kernel. Therefore I hacked up a small proxy to output NMEA records via TCP.

        # cat << EOF > /usr/libexec/gpsd/rfcomm_proxy
        #!/usr/bin/python3

        import bluetooth
        import logging
        import os
        import sys


        logging.basicConfig(level=logging.ERROR)
        log = logging.getLogger

        spp_uuid = "00001101-0000-1000-8000-00805f9b34fb"
        # c.f. https://www.freedesktop.org/software/systemd/man/sd_listen_fds.html
        SD_LISTEN_FDS_START = 3


        def rfcomm_client(addr, port, uuid=spp_uuid):
            port = port
            name = "SPP"
            host = addr
            log(__name__).info("Connecting profile %s of %s, %d", name, host, port)
            sock = bluetooth.BluetoothSocket(bluetooth.RFCOMM)
            sock.connect((host, port))
            return sock


        def data_loop(bt_socket):
            while True:
                try:
                    data = bt_socket.recv(1024)
                    os.write(SD_LISTEN_FDS_START, data)
                except Exception as e:
                    log(__name__).warning("Error in communication: %s", e)
                    break
            bt_sock.close()
            log(__name__).info("Sockets closed")
            os.system("pkill gpsd")


        bt_sock = rfcomm_client(sys.argv[1], int(sys.argv[2]))
        data_loop(bt_sock)
        EOF

And mark that file executable with `chmod 755 /usr/libexec/gpsd/rfcomm_proxy`.
    
To start it I want to use a systemd socket unit:

        # cat << EOF > /etc/systemd/user/rfcomm_proxy@.service
        [Unit]
        Description=Proxy RFCOMM bluetooth GPS receiver to tcp socket
        Requires=rfcomm_proxy.socket

        [Service]
        Type=simple
        EnvironmentFile=-/etc/default/gpsd
        EnvironmentFile=-/etc/sysconfig/gpsd
        ExecStart=/usr/libexec/gpsd/rfcomm_proxy $BT_MAC $BT_CHANNEL

        [Install]
        WantedBy=multi-user.target
        Also=rfcomm_proxy.socket
        EOF
    
... and ...

        # cat << EOF > /etc/systemd/user/rfcomm_proxy.socket 
        [Unit]
        Description=RFCOMM Proxy socket
        PartOf=rfcomm_proxy.service

        [Socket]
        ListenStream=127.0.0.1:1232
        Accept=yes
        MaxConnections=1

        [Install]
        WantedBy=sockets.target
        EOF

Now let's configure the service with 

        # cat << EOF > /etc/default/gpsd
        BT_MAC="00:1C:88:06:07:CF"
        BT_CHANNEL="1"
        EOF
    
and tell systemd to use that configuration:

        $ systemctl --user daemon-reload
        $ systemctl --user enable rfcomm_proxy.socket


Now systemd should be listening on port 1232 and start the rfcomm_proxy when a TCP client connects:

        $ socat tcp:localhost:1232 STDOUT
        $GPGSA,A,1,,,,,,,,,,,,,,,*1E
        $GPGSV,3,1,11,04,78,148,29,03,52,085,,09,47,216,,06,39,306,35*7F  
    
5. Install gpsd and make it work. 
 
        # zypper in gpsd gpsd-clients
    
Unfortunately the systemd unit shipped with gpsd renders it mostly useless. The culprit is that it is started as root and will programmatically drop its priviledges to nobody. On a Jolla user nobody is not allowed to do any useful work required by gpsd, like making network connections or opening devices. Hence I disabled the shipped systemd configuration and adapted the configuration shipped with gpsd on Debian.

        # systemctl disable gpsd
        # systemctl mask gpsd
    
Now use the same systemd activation as with rfcomm_proxy:

        # cat <<< EOF > /etc/systemd/user/gpsd.service 
        [Unit]
        Description=GPS (Global Positioning System) Daemon
        Requires=gpsd.socket

        [Service]
        Type=forking
        EnvironmentFile=-/etc/default/gpsd
        ExecStart=/usr/sbin/gpsd $GPSD_OPTIONS $OPTIONS $DEVICES

        [Install]
        WantedBy=multi-user.target
        Also=gpsd.socket
        EOF
    
... and ...

        # cat << EOF > /etc/systemd/user/gpsd.socket
        [Unit]
        Description=GPS (Global Positioning System) Daemon Sockets

        [Socket]
        ListenStream=[::1]:2947
        ListenStream=127.0.0.1:2947
        BindIPv6Only=yes

        [Install]
        WantedBy=sockets.target
        EOF
    
Now we should configure gpsd to use the NMEA source behind port 1232 as input:

        # cat << EOF >> /etc/default/gpsd
        USBAUTO="false"
        GPSD_OPTIONS=""
        DEVICES="tcp://localhost:1232"
        EOF
    
Again tell systemd to use that configuration:

        $ systemctl --user daemon-reload
        $ systemctl --user enable gpsd.socket
    
Now a TCP connection to port 2947 should start gpsd which in turn will connect to port 1232 starting rfcomm_proxy. To test that, cgps is a useful gpsd client for the terminal.

When the last gpsd client goes away, gpsd will remove the connection to the rfcomm_proxy, which will automatically kill gpsd.

6. Bind gpsd to geoclue

That setup is sufficient for software, that is able to use gpsd as positioning source (navit maybe, but probably not the sailfish port). For most apps we need to glue gpsd to geoclue. To do that, simply build and install the geoclue-gpsd3 provider from this repository. Calling build.sh should be enough to compile and package it, provided libgps-devel, geoclue-devel, and gcc are installed.

geoclue-master, which controls the other geoclue plugins, will only allow one provider of a certain kind. To use geoclue-gpsd3, you will have to temporyrily disable geoclue-hybris:

        # cd /usr/share/geoclue-providers
        # mv geoclue-hybris.provider geoclue-hybris.provider.disabled
        # pkill geoclue-master
    
To use geoclue-hybris, disable geoclue-gpsd3.provider instead.

7. Make stopping geoclue-gpsd3 work (not longer required for SailfishOS 4.5 and later)

One problem remains. Ending the last geoclue client should also end the bluetooth connection to the GPS mouse and stop gpsd. But there's a bug in libgeoclue, as shipped by Jolla, leading to this problem. The bug is already fixed in their public repository at https://github.com/sailfishos/geoclue but not included in Vanha Rauma. Building the library from source and installing it fixes the problem.





    
    
