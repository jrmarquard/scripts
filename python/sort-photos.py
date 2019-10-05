import os
import re
import shutil
from datetime import datetime, timedelta
import argparse

# Sort photos that occur before this time into the previous day
FOUR_AM = int("040000")
DAY_OVERLAP_CUTOFF = FOUR_AM

# Filenames: year, month, month_day, and time
REGEX_CAMERA_FILES = r'(\d{4})(\d{2})(\d{2})_(\d{6}).*'

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='This is my help')
    parser.add_argument('path', type=str,
                        help='The folder with photos to sort')
    args = parser.parse_args()
    dir_path = args.path

    files = [f for f in os.listdir(dir_path) if os.path.isfile(
        os.path.join(dir_path, f))]

    padding = len(str(len(files)))
    total_files = len(files)
    print("Processing {} files.".format(str(total_files).zfill(padding)))

    count = 1
    for file in files:
        print("[{}/{}]".format(str(count).zfill(padding),
                               str(total_files).zfill(padding)), end='\r')
        m = re.match(REGEX_CAMERA_FILES, file)

        if m:
            year = int(m.group(1))
            month = int(m.group(2))
            month_day = int(m.group(3))
            date = datetime(year, month, month_day)

            time = int(m.group(4))
            if time < DAY_OVERLAP_CUTOFF:
                date = date - timedelta(days=1)

            move_to_dir = date.strftime("%Y.%m.%d -")
        else:
            move_to_dir = "_ unsorted"

        sour_path = os.path.abspath(os.path.join(dir_path, file))
        dest_dir_path = os.path.join(dir_path, move_to_dir)
        dest_file_path = os.path.join(dir_path, dest_dir_path, file)

        if not os.path.exists(dest_dir_path):
            os.makedirs(dest_dir_path)

        shutil.move(sour_path, dest_dir_path)
        count += 1

    print()
    print("Done")
