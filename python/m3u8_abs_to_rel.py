# Change file paths in playlist file to be relative to folder and
# not absolute paths

import os
import sys
import re

ENCODING = 'utf-8'

if __name__ == "__main__":
    src_file_path = os.path.abspath(sys.argv[1])
    file_name = re.match(r'(.*)\\(.*)\.(.*)$', src_file_path)
    file_parent_path = file_name.group(1)
    file_title = file_name.group(2)
    file_ext = file_name.group(3)

    if (file_ext != 'm3u8'):
        raise Exception('File not m3u8')

    dst_file_path = os.path.join(
        file_parent_path, file_title + "_relative." + file_ext)

    edited_lines = list()
    with open(src_file_path, 'r', encoding=ENCODING) as fp:
        line = fp.readline()
        while line:
            curr_line = line.strip()
            line = fp.readline()
            file_name = re.match(
                r'.*\\([^\\]*)\\([^\\]*)\\([^\\]*)$', curr_line)
            if file_name:
                album_artist = file_name.group(1)
                album = file_name.group(2)
                song_file_name = file_name.group(3)
                edited_lines.append(album_artist + " - " +
                                    album + "\\" + song_file_name)
                print(edited_lines[-1])

    with open(dst_file_path, 'w', encoding=ENCODING) as f:
        for item in edited_lines:
            f.write("%s\n" % item)

    print()
    print("Done")
