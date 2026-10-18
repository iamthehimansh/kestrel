"""Bounded observation of one ADB serial after restoring its owned test VM."""
import time


def wait_for_adb(command, adb, serial, env, log, timeout=30, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    next_log = clock()
    last = 'not checked'
    while clock() < deadline:
        remaining = deadline - clock()
        try:
            state = command([adb, '-s', serial, 'get-state'], env, min(3, remaining)).strip()
            if state == 'device':
                ready = command([adb, '-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
                                env, max(0.1, min(3, deadline - clock()))).strip()
                if ready == '1' and clock() < deadline:
                    return
                last = 'ADB connected, Android boot completion=' + ready
            else:
                last = 'ADB state=' + state
        except RuntimeError as error:
            last = str(error)
        if clock() >= next_log:
            log('  Waiting for same device after restore: ' + last)
            next_log = clock() + 10
        sleep(max(0, min(1, deadline - clock())))
    raise RuntimeError('Post-restore ADB readiness deadline exceeded: ' + last)
