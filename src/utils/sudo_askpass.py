import os, tempfile, stat, textwrap

def make_askpass_script():
    script = textwrap.dedent("""\
        #!/bin/bash
        /usr/bin/osascript -e '
            tell application "System Events"
                activate
                display dialog "BookMaster needs your password to write the disk image." with title "Permission Required" with icon caution default answer "" buttons {"OK"} default button "OK" with hidden answer
            end tell
        ' -e 'text returned of result'
    """)
    fd, path = tempfile.mkstemp(prefix="askpass_", text=True)
    with os.fdopen(fd, "w") as f:
        f.write(script)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path