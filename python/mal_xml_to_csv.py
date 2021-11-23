# Converts XML of MAL mangalist to CSV
import xml.etree.ElementTree as element_tree
import pandas as pd
import os
import argparse

def get_arguments():
    parser = argparse.ArgumentParser(description='Converts XML of MAL mangalist to CSV')
    parser.add_argument('file_in', type=str, help='The XML file to read')
    parser.add_argument('file_out', type=str, help='The CSV file to generate')
    args = parser.parse_args()
    file_in = os.path.abspath(args.file_in)
    file_out = os.path.abspath(args.file_out)
    return file_in, file_out


def main(file_in, file_out):
    rows = []
    
    file_tree = element_tree.parse(file_in)
    file_root = file_tree.getroot()

    # document structure: myanimelist > manga[]
    manga_arr = file_root.findall('manga')

    print('[info] processing')
    for manga in manga_arr:
        manga_dict = xml_element_to_dict(manga)
        rows.append(manga_dict)
        # title = manga.find("manga_title").text
        # print('[info] manga: ' + title)

    df = pd.DataFrame(rows)
    print('[info] done. rows: ' + str(len(rows)))
    
    # Writing dataframe to csv
    df.to_csv(file_out, index=False)


def xml_element_to_dict(element):
    new_dict = {}
    for item in list(element):
        new_dict[item.tag] = item.text
    return new_dict


if __name__ == "__main__":
    file_in, file_out = get_arguments()
    main(file_in=file_in, file_out=file_out)