import csv
import os
import argparse


def clean_cell(cell_str):
    if "," in cell_str:
        return '"' + cell_str + '"'
    else:
        return cell_str


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='This is my help')
    parser.add_argument('file_in', type=str, help='The csv file to flip')
    parser.add_argument('file_out', type=str, help='output file')
    args = parser.parse_args()
    file_path_in = os.path.abspath(args.file_in)
    file_path_out = os.path.abspath(args.file_out)

    new_csv_rows = []

    with open(file_path_in, 'r') as csvfile:
        for row in reversed(list(csv.reader(csvfile))):
            cleaned_row = [clean_cell(cell) for cell in row]
            new_csv_rows.append(", ".join(cleaned_row))
    
    with open(file_path_out, 'w') as outfile:
        for row in new_csv_rows:
            outfile.write(row + '\n')