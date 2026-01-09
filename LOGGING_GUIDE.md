# RSWarehouse Logging Guide

## Overview
The RSWarehouse script includes comprehensive logging to help troubleshoot issues with work request fulfillment, RS Bridge exports, and autocrafting operations.

---

## Log File Location

**File:** `RSWarehouse.log`  
**Location:** Same directory as the RSWarehouse.lua script (typically the root of your computer in ComputerCraft)

---

## How to Access Logs

### Method 1: Using the `edit` Command (In-Game)
```lua
edit RSWarehouse.log
```
- Opens the log file in CC:Tweaked's text editor
- Use arrow keys to scroll through entries
- Press `Ctrl` to access menu, then choose "Exit" to close

### Method 2: Using the `cat` Command (In-Game)
```lua
cat RSWarehouse.log
```
- Displays the entire log file contents in the terminal
- Good for quick viewing of recent logs
- Will scroll quickly if file is large

### Method 3: View Recent Entries with `tail`
Many CC:Tweaked systems have a tail-like function. If not available, you can create a simple viewer:
```lua
local f = fs.open("RSWarehouse.log", "r")
local content = f.readAll()
f.close()
print(content:sub(-2000)) -- Last 2000 characters
```

### Method 4: Copy to Another Computer
```lua
-- On the RSWarehouse computer:
-- Insert a disk
fs.copy("RSWarehouse.log", "disk/RSWarehouse.log")

-- On another computer with the disk:
edit disk/RSWarehouse.log
```

---

## Log Format

Each log entry follows this format:
```
[Day X HH:MM] [LEVEL] Message
  Data: {key=value, ...}
```

### Log Levels

- **INFO**: Normal operations, successful actions
- **WARN**: Non-critical issues, export failures (before crafting attempt)
- **ERROR**: Critical failures, both export and craft failed
- **DEBUG**: Detailed information for troubleshooting

---

## Common Log Entries Explained

### Startup
```
================================================================================
RSWarehouse started - Day X at HH:MM
Advanced Peripherals 0.7 Compatible
================================================================================
[Day X HH:MM] [INFO] Monitor initialized successfully
[Day X HH:MM] [INFO] RS Bridge initialized successfully
[Day X HH:MM] [INFO] Colony Integrator initialized successfully
  Data: {inColony=true}
```
**Meaning:** Script started successfully, all peripherals connected.

---

### Scan Operations
```
[Day X HH:MM] [INFO] === SCAN STARTED ===
  Data: {time=6.5, day=42}
[Day X HH:MM] [INFO] Retrieved work requests from colony
  Data: {count=5}
```
**Meaning:** New scan cycle started, found 5 work requests.

---

### Successful Export
```
[Day X HH:MM] [INFO] Processing work request
  Data: {name="Oak Wood", needed=64, colonist="Builder John Doe"}
[Day X HH:MM] [INFO] Export successful
  Data: {item="Oak Wood", exported=64, needed=64}
[Day X HH:MM] [INFO] Request fully satisfied from storage
  Data: {item="Oak Wood", provided=64}
```
**Meaning:** Successfully exported 64 Oak Wood from RS storage.
**Monitor Color:** 🟢 GREEN

---

### Partial Export + Crafting
```
[Day X HH:MM] [INFO] Export successful
  Data: {item="Glass", exported=32, needed=64}
[Day X HH:MM] [INFO] Attempting to craft remaining items
  Data: {item="Glass", remaining=32}
[Day X HH:MM] [INFO] Crafting scheduled
  Data: {item="Glass", count=32, jobId="abc123"}
```
**Meaning:** Only 32 Glass in storage, crafting the remaining 32.
**Monitor Color:** 🟡 YELLOW

---

### Export Failed, Crafting Attempted
```
[Day X HH:MM] [WARN] Export failed
  Data: {item="Iron Ingot", error="ITEM_NOT_FOUND"}
[Day X HH:MM] [INFO] Attempting to craft full amount
  Data: {item="Iron Ingot", count=10}
[Day X HH:MM] [INFO] Crafting scheduled
  Data: {item="Iron Ingot", count=10, jobId="def456"}
```
**Meaning:** No Iron Ingots in storage, scheduled crafting for all 10.
**Monitor Color:** 🟡 YELLOW

---

### Both Export and Craft Failed
```
[Day X HH:MM] [WARN] Export failed
  Data: {item="Diamond", error="ITEM_NOT_FOUND"}
[Day X HH:MM] [ERROR] Both export and crafting failed
  Data: {item="Diamond", exportError="ITEM_NOT_FOUND", craftError="NO_PATTERN"}
```
**Meaning:** No Diamonds in storage AND no crafting pattern configured.
**Monitor Color:** 🔴 RED
**Action Required:** Add Diamonds to RS system or create a pattern.

---

### Partial Export, Craft Failed
```
[Day X HH:MM] [INFO] Export successful
  Data: {item="Bread", exported=5, needed=10}
[Day X HH:MM] [ERROR] Crafting failed
  Data: {item="Bread", error="pattern not found"}
```
**Meaning:** Got 5 Bread from storage but can't craft the remaining 5.
**Monitor Color:** 🟠 ORANGE
**Action Required:** Add a crafting pattern for Bread or manually fulfill.

---

### Skipped Items
```
[Day X HH:MM] [INFO] Item skipped - manual fulfillment required
  Data: {name="Iron Sword", desc="Tool of class...", colonist="Guard Jane Smith"}
```
**Meaning:** Item requires manual fulfillment (tools, equipment, etc.).
**Monitor Color:** 🔵 BLUE
**Action Required:** Manually deliver the item to the colonist.

---

### Scan Completion
```
[Day X HH:MM] [INFO] === SCAN COMPLETED ===
  Data: {totalRequests=8, builderRequests=3, nonbuilderRequests=4, equipmentRequests=1}
```
**Meaning:** Scan finished processing all requests.

---

## Troubleshooting Common Issues

### Issue: "Monitor not found"
**Log Entry:**
```
[ERROR] Monitor not found - cannot initialize
```
**Solution:** Ensure a monitor is connected to the computer via wired modem or directly adjacent.

---

### Issue: "RS Bridge not found"
**Log Entry:**
```
[ERROR] RS Bridge not found - ensure peripheral is connected
```
**Solution:** 
1. Check that RS Bridge block is placed and connected
2. Verify Advanced Peripherals mod is installed (version 0.7)
3. Ensure peripheral name is `rs_bridge` (not `rsBridge`)

---

### Issue: "Colony Integrator is not in a colony"
**Log Entry:**
```
[ERROR] Colony Integrator is not in a colony - must be placed within colony boundaries
```
**Solution:** Move the Colony Integrator block within your MineColonies colony boundaries.

---

### Issue: Items not exporting
**Look for:**
```
[WARN] Export failed
  Data: {item="...", error="..."}
```
**Common Errors:**
- `ITEM_NOT_FOUND`: Item not in RS system
- `NO_SPACE`: Target inventory is full
- `UNKNOWN`: Check RS Bridge placement and connection

---

### Issue: Crafting not working
**Look for:**
```
[ERROR] Crafting failed
  Data: {item="...", error="..."}
```
**Common Errors:**
- `pattern not found` or `NO_PATTERN`: No crafting pattern configured in RS
- `NO_INGREDIENTS`: Pattern exists but missing crafting materials
- Check RS system has the pattern and required materials

---

## Log Maintenance

### Clearing Old Logs
The log file appends data, so it will grow over time. To clear it:
```lua
fs.delete("RSWarehouse.log")
-- Restart the script to create a fresh log
```

### Viewing Log Size
```lua
print("Log size: " .. fs.getSize("RSWarehouse.log") .. " bytes")
```

### Creating a Backup
```lua
-- Before clearing, backup old logs
local date = os.day()
fs.copy("RSWarehouse.log", "RSWarehouse_backup_day" .. date .. ".log")
fs.delete("RSWarehouse.log")
```

---

## Advanced: Real-Time Log Monitoring

Create a separate monitoring script to watch logs in real-time:

```lua
-- logmonitor.lua
local function tail(filename, lines)
  if not fs.exists(filename) then return end
  local f = fs.open(filename, "r")
  local content = f.readAll()
  f.close()
  
  local lineTable = {}
  for line in content:gmatch("[^\n]+") do
    table.insert(lineTable, line)
  end
  
  local start = math.max(1, #lineTable - lines + 1)
  for i = start, #lineTable do
    print(lineTable[i])
  end
end

while true do
  term.clear()
  term.setCursorPos(1, 1)
  print("=== RSWarehouse Live Logs ===")
  tail("RSWarehouse.log", 15)
  sleep(5)
end
```

---

## Understanding Data Fields

### Common Data Fields in Logs:

- **`name`**: Display name of the requested item
- **`itemName`**: Minecraft item ID (e.g., `minecraft:oak_planks`)
- **`count`** / **`needed`**: Quantity required
- **`exported`** / **`provided`**: Quantity delivered
- **`hasNBT`**: Whether item has special data (enchantments, etc.)
- **`colonist`**: Name and job of the requesting citizen
- **`error`**: Error message from RS Bridge or Colony Integrator
- **`jobId`**: Crafting job ID for tracking in RS system

---

## Best Practices

1. **Check logs after setup** to ensure all peripherals initialized correctly
2. **Review logs when items aren't being fulfilled** to identify the bottleneck
3. **Look for ERROR entries** first when troubleshooting
4. **Monitor crafting failures** - they indicate missing patterns
5. **Archive logs periodically** to keep file size manageable (every few in-game weeks)

---

## Questions?

If you encounter issues not covered in this guide:
1. Check the full log file for ERROR and WARN entries
2. Note the specific error messages
3. Verify all peripherals are connected (monitor, rs_bridge, colony_integrator)
4. Ensure RS system has patterns and materials
5. Check that items are within the RS system's reach

---

**Script Version:** Advanced Peripherals 0.7 Compatible  
**Last Updated:** 2025-01-06
