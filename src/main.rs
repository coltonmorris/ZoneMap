use wow_adt::Adt;

use base64::{engine::general_purpose, Engine as _};

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

/// Root ADT filename parser.
/// Accepts: "<map>_<x>_<y>.adt"
/// Rejects: "<map>_<x>_<y>_obj0.adt", "_tex0.adt", "_lod.adt", etc.
fn parse_root_adt_filename(path: &Path) -> Option<(String, u32, u32)> {
    if path.extension()?.to_str()?.to_ascii_lowercase() != "adt" {
        return None;
    }
    let stem = path.file_stem()?.to_str()?.to_string();
    let parts: Vec<&str> = stem.split('_').collect();
    if parts.len() != 3 {
        return None;
    }
    let map = parts[0].to_string();
    let x: u32 = parts[1].parse().ok()?;
    let y: u32 = parts[2].parse().ok()?;
    Some((map, x, y))
}

fn tile_key(tile_x: u32, tile_y: u32) -> u32 {
    tile_y * 64 + tile_x
}

/// Pack 256 u32 areaIDs into 1024 bytes LE, then base64 (no compression).
fn encode_tile_b64(area_ids_256: &[u32]) -> Result<String, Box<dyn std::error::Error>> {
    if area_ids_256.len() != 256 {
        return Err(format!("expected 256 area IDs, got {}", area_ids_256.len()).into());
    }

    let mut raw = Vec::with_capacity(256 * 4);
    for &v in area_ids_256 {
        raw.extend_from_slice(&v.to_le_bytes());
    }

    Ok(general_purpose::STANDARD.encode(&raw))
}

/// Parse a single root ADT and return 256 area IDs (16x16 chunks).
fn parse_adt_areaids(path: &Path) -> Result<Option<Vec<u32>>, Box<dyn std::error::Error>> {
    let data = fs::read(path)?;
    let adt = Adt::from_reader(Cursor::new(data))?;

    let mut area_ids: Vec<u32> = adt
        .mcnk_chunks
        .iter()
        .map(|chunk| chunk.area_id)
        .collect();

    if area_ids.is_empty() {
        return Ok(None);
    }
    
    if area_ids.len() != 256 {
        area_ids.resize(256, 0);
    }

    Ok(Some(area_ids))
}

/// Per-tile grid export container
struct TileGridExport {
    continent_name: String,
    tiles: BTreeMap<u32, String>,
}

impl TileGridExport {
    fn new(continent_name: &str) -> Self {
        Self {
            continent_name: continent_name.to_string(),
            tiles: BTreeMap::new(),
        }
    }

    fn export_lua(&self, out_path: &Path) -> std::io::Result<()> {
        let mut f = File::create(out_path)?;

        writeln!(f, "-- Auto-generated AreaID grid for {}", self.continent_name)?;
        writeln!(f, "-- Each tile is 16x16 chunks (256 u32 AreaIDs), base64 encoded.")?;
        writeln!(f)?;
        writeln!(f, "local _, addon = ...")?;
        writeln!(f)?;
        writeln!(f, "local tiles = {{")?;

        for (k, v) in &self.tiles {
            writeln!(f, "  [{}] = [[{}]],", k, v)?;
        }

        writeln!(f, "}}")?;
        writeln!(f)?;
        writeln!(f, "addon:RegisterTileGrid(\"{}\", {{", self.continent_name)?;
        writeln!(f, "  name = \"{}\",", self.continent_name)?;
        writeln!(f, "  tileSize = 16,")?;
        writeln!(f, "  tilesPerSide = 64,")?;
        writeln!(f, "  tiles = tiles,")?;
        writeln!(f, "}})")?;
        Ok(())
    }
}

fn build_tile_export(adt_dir: &Path, continent_name: &str) -> Result<TileGridExport, Box<dyn std::error::Error>> {
    let mut export = TileGridExport::new(continent_name);

    if !adt_dir.exists() {
        return Err(format!("Directory not found: {}", adt_dir.display()).into());
    }

    println!("Scanning: {}", adt_dir.display());

    let mut parsed = 0usize;

    for entry in fs::read_dir(adt_dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let Some((_, tx, ty)) = parse_root_adt_filename(&path) else {
            continue;
        };

        match parse_adt_areaids(&path) {
            Ok(Some(area_ids)) => {
                let b64 = encode_tile_b64(&area_ids)?;
                let key = tile_key(tx, ty);
                export.tiles.insert(key, b64);
                parsed += 1;
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("  ERROR parsing {}: {}", path.display(), e);
            }
        }
    }

    println!("  Parsed {} tiles", parsed);
    Ok(export)
}

fn generate_continent(dir_name: &str, continent_name: &str, out_dir: &Path) {
    let adt_dir = PathBuf::from(dir_name);
    let out_path = out_dir.join(format!("{}_tiles.lua", continent_name));
    
    match build_tile_export(&adt_dir, continent_name) {
        Ok(export) => {
            if let Err(e) = export.export_lua(&out_path) {
                eprintln!("Failed to write {}: {}", out_path.display(), e);
            } else {
                println!("  Wrote: {}", out_path.display());
            }
        }
        Err(e) => {
            eprintln!("Skipping {} - {}", continent_name, e);
        }
    }
}

fn main() {
    println!("ZoneMap Tile Generator\n");
    
    // Create Data directory if it doesn't exist
    let out_dir = Path::new("Data");
    if !out_dir.exists() {
        if let Err(e) = fs::create_dir(out_dir) {
            eprintln!("Failed to create Data directory: {}", e);
            return;
        }
        println!("Created Data/ directory");
    }
    
    // Generate Kalimdor tiles
    generate_continent("kalimdor_adts", "Kalimdor", out_dir);
    
    // Generate Azeroth (Eastern Kingdoms) tiles
    generate_continent("azeroth_adts", "Azeroth", out_dir);
    
    println!("\nDone!");
}
