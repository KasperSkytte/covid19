import csv
import uuid
import re

from pandas import read_excel
from datetime import date, datetime, timedelta
from enum import Enum

CONFIG_FILEPATH = "/srv/rbd/mp/covid19/bi_system/config.json"

QUERY =     'SELECT P.ssi_id, date, C.low_res_clade, R.code, R.longitude, R.latitude, day(date), month(date), year(date)' \
            'FROM Persons P LEFT OUTER JOIN Municipalities M ON P.MunicipalityCode=M.code LEFT OUTER JOIN NUTS3_Regions R ON M.region=R.code ' \
            'JOIN Clade_assignment C ON P.ssi_id =  C.ssi_id ' \
            ';'

class FIELD():
      ID = "ID"
      orig_id = "orig_id"
      sample_date = "sample_date"
      epi_week= "epi_weel"
      country="country"
      region="region__autocolor"
      lineage="lineage__autocolor"
      latitude="latitude"
      longitude="longitude"
      day="day"
      month="month"
      year="year"

def execute_query(connection, query):
      cursor = connection.cursor()
      cursor.execute(query)
      records = cursor.fetchall()

      assert len(records) > 0, "Query resulted in 0 records."
      return records

def convert_to_microreact_format(data):
      formatted_data = []
      epidemic_start_date = _get_epi_start_date(data)
      for e in data:
            week_start_date = _get_first_day_of_week(e[1])
            data_obj = {
                  FIELD.ID:str(uuid.uuid4()),
                  FIELD.orig_id:e[0],
                  FIELD.sample_date:e[1].isocalendar()[1],
                  FIELD.epi_week:_get_epi_week(e[1], epidemic_start_date),
                  FIELD.country:"DK01",
                  FIELD.region:e[3],
                  FIELD.lineage:e[2],
                  FIELD.latitude:e[5],
                  FIELD.longitude:e[4],
                  FIELD.day:week_start_date.day,
                  FIELD.month:week_start_date.month,
                  FIELD.year:week_start_date.year
            }
            formatted_data.append(data_obj)
      return formatted_data

def save_tree(config, tree):
      path = config['out_react_nwk']
      print('Saving tree to {}'.format(path))
      with open(path, "w") as f:
            f.write(tree)

def get_tree(config):
      path = config['clade_tree_path']
      with open(path, "r") as f:
            return f.read()

def replace_tree_ids(data, tree):
    for e in data:
        replacement_id = e[FIELD.ID]
        original_id = e[FIELD.orig_id]

        match_idx = _find_replacement_idx(tree, original_id)
        if match_idx == -1:
            print("Failed to find and replace ID: {}".format(original_id))
            continue

        tree = tree[:match_idx] + replacement_id + tree[match_idx + len(original_id):]
    return tree

def filter_data_by_min_cases(data, config, min_cases=3):
      cases = _get_cases_per_region_week(config['raw_ssi_file'])
      filtered_data = []
      skipped_ids = []
      for example in data:
            match = cases.loc[(cases['Week'] == example[FIELD.sample_date]) & (cases['NUTS3Code'] == example[FIELD.region])]
            if len(match.index) != 1:
                  print("Cases did not properly match the example, continuing... (cases: {}, id: {})".format(len(match.index), example[FIELD.orig_id]))
                  skipped_ids.append(example[FIELD.ID])
                  continue
            if match['Cases'].iloc[0] < min_cases:
                  skipped_ids.append(example[FIELD.ID])
                  continue
            filtered_data.append(example)
      return filtered_data, skipped_ids

def get_unmatched_ids_in_tree(tree, id_prefix_lst):
    ids = []
    keys = ["SSI-", "HH-", "Wuhan/", "AAU-"]
    for key in keys:
        for match in re.finditer(key, tree):
            start_idx = match.start()
            end_idx = tree[start_idx:start_idx + 50].index(":") + start_idx
            ids.append(tree[start_idx:end_idx])
    return ids

def add_empty_records(data, skipped_ids):
      for skipped_id in skipped_ids:
            empty_data_obj = {
                  FIELD.ID:skipped_id,
                  FIELD.orig_id:None,
                  FIELD.sample_date:None,
                  FIELD.epi_week:None,
                  FIELD.country:None,
                  FIELD.region:None,
                  FIELD.lineage:None,
                  FIELD.latitude:None,
                  FIELD.longitude:None,
                  FIELD.day:None,
                  FIELD.month:None,
                  FIELD.year:None
            }
            data.append(empty_data_obj)
      return data

def save_csv(config, data):
      path = config['out_react_tsv']
      print('Saving data to {}'.format(path))
      with open(path, "w") as f:
            writer = csv.DictWriter(f,
                  fieldnames=[FIELD.ID, FIELD.sample_date, FIELD.epi_week, FIELD.country, FIELD.region, FIELD.lineage, FIELD.latitude, FIELD.longitude, 
                        FIELD.day, FIELD.month, FIELD.year])
            writer.writeheader()
            for data_obj in data:
                  del data_obj[FIELD.orig_id]
                  writer.writerow(data_obj)

def _get_first_day_of_week(date):
      return date - timedelta(days=date.weekday())

def _get_epi_week(infected_date, epidemic_start_date):
      w_start_infected = infected_date - timedelta(days=infected_date.weekday())
      w_start_epidemic = epidemic_start_date - timedelta(days=epidemic_start_date.weekday())
      return (_get_first_day_of_week(w_start_infected) - _get_first_day_of_week(w_start_epidemic)).days / 7

def _get_epi_start_date(data): 
      return min(e[1] for e in data)

def _datestr_to_week_func():
      return lambda date: datetime.strptime(date, '%Y-%m-%d').isocalendar()[1]

def _get_cases_per_region_week(linelist_filepath):
      linelist=read_excel(linelist_filepath)
      assert linelist.empty == False
      linelist['Week']=linelist['SampleDate'].apply(_datestr_to_week_func())
      return linelist.groupby(['Week', 'NUTS3Code']).size().reset_index(name="Cases")

def _find_replacement_idx(tree, key):
      for match in re.finditer(key, tree):
           if tree[match.end()] != ":":
                continue
           return match.start()
      return -1

