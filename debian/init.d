#! /bin/sh

### BEGIN INIT INFO
# Provides:          scron
# Required-Start:    $network $local_fs
# Required-Stop:     $network $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      1
# Short-Description: scron server
### END INIT INFO

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/usr/sbin/scrond
NAME=scrond
DESC=scrond
PIDFILE=/var/run/scrond.pid

test -x $DAEMON || exit 0

# Include defaults if available
if [ -f /etc/default/$NAME ] ; then
	. /etc/default/$NAME
fi

set -e

case "$1" in
  start)
	echo -n "Starting $DESC: "

  	if ! $DAEMON --check > /dev/null 2>&1; then
            echo "failed config check.  Run '$DAEMON --check' for details."
            exit 1
	fi

	start-stop-daemon --start --quiet --exec $DAEMON -- $DAEMON_OPTS
	echo "$NAME."
	;;
  stop)
  	if [ -f $PIDFILE ]; then
            echo -n "Stopping $DESC: "
            start-stop-daemon --stop --quiet --name $NAME --pidfile $PIDFILE
            echo "$NAME."
            rm $PIDFILE
	fi
	;;
  restart|force-reload)
  	if [ -f $PIDFILE ]; then
            echo -n "Restarting $DESC: "

            if ! $DAEMON --check > /dev/null 2>&1; then
                echo "failed config check.  Run '$DAEMON --check' for details."
                exit 1
            fi

            start-stop-daemon --stop --quiet --name $NAME --pidfile $PIDFILE

            sleep 1

            start-stop-daemon --start --quiet --exec $DAEMON -- $DAEMON_OPTS
            echo "$NAME."
	fi
	;;
  reload)
        echo -n "Reloading $DESC: "

  	if ! [ -f $PIDFILE ]; then
            echo "Pid file $PIDFILE doesn't exist.  Can't reload."
            exit 1
	fi

  	if ! $DAEMON --check > /dev/null 2>&1; then
            echo "failed config check.  Run '$DAEMON --check' for details."
            exit 1
	fi
		
        kill -HUP `cat $PIDFILE`
        echo "$NAME."
	;;
  *)
	N=/etc/init.d/$NAME
	echo "Usage: $N {start|stop|restart|reload}" >&2
	exit 1
	;;
esac

exit 0
