-- RSWarehouse Configuration
-- Edit this file to customize your setup

return {
    -- GitHub repository for updates
    -- Format: "username/repository"
    github_repo = "BRid37/ColonyManager-Pro-RS",
    github_branch = "main",
    
    -- Scan settings
    time_between_runs = 15,
    scan_at_night = true,
    
    -- Logging settings
    verbose_logging = false,
    max_log_size = 50000,
    log_rotate_enabled = true,
    
    -- Storage direction (relative to RS Bridge)
    storage_direction = "back",
    
    -- Excluded items list
    -- Items in this list will never be auto-fulfilled
    -- Use exact item names or Lua patterns
    excluded_items = {
        -- Example: "Diamond Pickaxe",
        -- Example: "Rallying Banner",
    },
    
    -- Excluded item categories
    -- These categories are always excluded (handled specially or need manual fulfillment)
    excluded_categories = {
        "Compostable",
        "Fertilizer", 
        "Flowers",
        "Food",
        "Fuel",
        "Smeltable Ore",
        "Stack List",
        "Crafter",
        "Rallying Banner"
    },
    
    -- Smart tool handling
    -- When enabled, provides the cheapest acceptable tool based on building level
    smart_tool_handling = true,
    
    -- When true, attempts to provide tools even if not explicitly requested
    -- (e.g., provide wooden pickaxe when "Tool of class" is requested)
    auto_fulfill_tool_requests = true,
    
    -- Material tier costs (lower = cheaper, prioritized first)
    material_costs = {
        ["wooden"] = 1,
        ["wood"] = 1,
        ["gold"] = 1,
        ["golden"] = 1,
        ["stone"] = 2,
        ["iron"] = 3,
        ["diamond"] = 5,
        ["netherite"] = 10
    },
    
    -- Building level to maximum allowed tool tier
    -- Format: building_level = {allowed_materials}
    -- MineColonies rules:
    --   Level 0: Wood or Gold only
    --   Level 1: Up to Stone
    --   Level 2: Up to Iron
    --   Level 3: Up to Diamond
    --   Level 4+: Up to Diamond (Netherite with research)
    building_tool_tiers = {
        [0] = {"wooden", "wood", "gold", "golden"},
        [1] = {"wooden", "wood", "gold", "golden", "stone"},
        [2] = {"wooden", "wood", "gold", "golden", "stone", "iron"},
        [3] = {"wooden", "wood", "gold", "golden", "stone", "iron", "diamond"},
        [4] = {"wooden", "wood", "gold", "golden", "stone", "iron", "diamond"},
        [5] = {"wooden", "wood", "gold", "golden", "stone", "iron", "diamond", "netherite"}
    },
    
    -- Armor level mappings (similar to tools)
    -- Level 0: Leather only
    -- Level 1: Gold or Leather
    -- Level 2: Chain
    -- Level 3: Iron
    -- Level 4+: Diamond
    building_armor_tiers = {
        [0] = {"leather"},
        [1] = {"leather", "gold", "golden"},
        [2] = {"leather", "gold", "golden", "chain", "chainmail"},
        [3] = {"leather", "gold", "golden", "chain", "chainmail", "iron"},
        [4] = {"leather", "gold", "golden", "chain", "chainmail", "iron", "diamond"},
        [5] = {"leather", "gold", "golden", "chain", "chainmail", "iron", "diamond", "netherite"}
    },
    
    -- Tool types that can be auto-fulfilled
    tool_types = {
        "Pickaxe",
        "Axe", 
        "Shovel",
        "Hoe",
        "Sword",
        "Bow",
        "Shield"
    },
    
    -- Armor types that can be auto-fulfilled
    armor_types = {
        "Helmet",
        "Chestplate",
        "Leggings",
        "Boots",
        "Cap",
        "Tunic",
        "Pants"
    },
    
    -- Cache citizen/building data (reduces API calls)
    cache_colony_data = true,
    cache_duration = 60,  -- seconds
    
    -- Disable buildings API to prevent server crashes
    -- Some versions of Advanced Peripherals/MineColonies have incompatible APIs
    -- that cause NoSuchMethodError crashes. Set to true to disable getBuildings() calls.
    -- This disables building-level-based tool tier selection but prevents crashes.
    disable_buildings_api = true
}
