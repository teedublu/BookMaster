"""
Configuration settings for the application.
"""

class Config:
    def __init__(self, debug=False):
        self.debug = debug
        self.output_folder = "/path/to/output"  # Default path
        self.processed_folder = "/path/to/processed"  # Default path
        self.params = {}
        self.output_structure = {
            "tracks_path": "tracks",
            "info_path": "bookInfo",
            "id_file": "bookInfo/id.txt",
            "count_file": "bookInfo/count.txt",
        }
    
    def __repr__(self):
        return f"Config(debug={self.debug})"
