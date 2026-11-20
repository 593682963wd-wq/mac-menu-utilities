import unittest,tempfile,json
from pathlib import Path
from core import run

class Tests(unittest.TestCase):
 def test_countdown(self):self.assertEqual(run(json.loads(Path('example.json').read_text()))['remaining_seconds'],3600)
 def test_empty(self):
  with self.assertRaises(KeyError):run({})
 def test_bad(self):
  p=json.loads(Path('example.json').read_text());p['reminder_minutes']=0
  with self.assertRaises(ValueError):run(p)

if __name__=="__main__":unittest.main()
