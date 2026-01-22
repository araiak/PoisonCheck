# PoisonCheck

Alerts rogues when missing lethal or non-lethal poisons, with Dragon-Tempered Blades talent support.

## Features

- Alerts when missing lethal or non-lethal poisons
- Automatically detects Dragon-Tempered Blades talent (requires 2 of each poison type)
- Warns when poisons are expiring soon (< 15 minutes) during ready checks and queue pops
- Visual raid warning and optional sound alert
- Checks on login, zone changes, group joins, ready checks, and M+ starts

## Commands

| Command | Description |
|---------|-------------|
| `/pc` or `/pc help` | Show available commands |
| `/pc status` | Show current poison status and durations |
| `/pc check` | Force a poison check |
| `/pc toggle` | Enable/disable alerts |
| `/pc sound` | Toggle sound alerts |
| `/pc debug` | Scan buffs to find poison spell IDs |

## Supported Poisons

**Lethal:** Deadly Poison, Instant Poison, Wound Poison, Amplifying Poison

**Non-Lethal:** Crippling Poison, Numbing Poison, Atrophic Poison

## Installation

1. Download and extract to your `World of Warcraft\_retail_\Interface\AddOns\` folder
2. Ensure the folder is named `PoisonCheck`
3. Restart WoW or type `/reload`
