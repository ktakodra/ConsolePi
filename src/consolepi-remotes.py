#!/etc/ConsolePi/venv/bin/python3

import json
import os
import sys
from consolepi.common import ConsolePi_data
from consolepi.common import set_perm

config = ConsolePi_data(do_print=False)
local_cloud_file = config.LOCAL_CLOUD_FILE  # pylint: disable=maybe-no-member
data = config.remotes

if len(sys.argv) == 1:
    print(json.dumps(data, indent=4, sort_keys=True))
elif len(sys.argv) == 2:
    if sys.argv[1] in data:
        print(json.dumps(data[sys.argv[1]], indent=4, sort_keys=True))
    else:
        print('{} not found in file.  Printing all hosts'.format(sys.argv[1]))
        print(json.dumps(data, indent=4, sort_keys=True))
elif len(sys.argv) == 3:
    if sys.argv[1] == 'del':
        if sys.argv[2] in data:
            print('Removing ' + sys.argv[2] + ' from local cloud cache')
            data.pop(sys.argv[2])
            if os.path.isfile(local_cloud_file):
                os.remove(local_cloud_file)
            with open(local_cloud_file, 'a') as new_file:
                new_file.write(json.dumps(data, indent=4, sort_keys=True))
                set_perm(local_cloud_file)
            print('Remotes remaining in local cache')
            print(json.dumps(data, indent=4, sort_keys=True))
            print('{} Removed from local cache'.format(sys.argv[2]))
        else:
            print('{} not found in file.  Printing all hosts'.format(sys.argv[2]))
            print(json.dumps(data, indent=4, sort_keys=True))
    else:
        print('Invalid argument {}'.format(sys.argv[1]))
else:
    print('Too many Arguments.  Printing all hosts')
    print(json.dumps(data, indent=4, sort_keys=True))