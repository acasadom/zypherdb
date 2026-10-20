//! Loads the benchmark graph's CSV files into a SparrowDB database with its BulkLoader.
//!
//!     sparrow-loader DB_DIR CSV_DIR
use std::path::Path;
use sparrowdb::{bulk::{BulkLoader, BulkOptions}, GraphDb};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (db_dir, csv) = (Path::new(&args[1]), Path::new(&args[2]));
    let db = GraphDb::open(db_dir).expect("open");
    let loader = BulkLoader::new(&db, BulkOptions::default());
    for label in ["Person", "Card", "Team", "Zone", "Door"] {
        loader.load_nodes(&csv.join(format!("{label}.csv")), label).expect("nodes");
    }
    for (file, rel, from, to) in [
        ("HELD_BY", "HELD_BY", "Card", "Person"),
        ("MEMBER_OF_person", "MEMBER_OF", "Person", "Team"),
        ("MEMBER_OF_team", "MEMBER_OF", "Team", "Team"),
        ("LOCATED_IN", "LOCATED_IN", "Door", "Zone"),
    ] {
        loader.load_edges(&csv.join(format!("{file}.csv")), rel, from, to).expect("edges");
    }
}
