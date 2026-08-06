std = "lua51"
max_line_length = false
codes = true

-- ponytail: WoW's API is one giant global namespace; enumerating it here is a
-- maintenance treadmill that goes stale every patch. So we ignore reads of
-- undefined globals (113) and declare only this addon's own globals below, which
-- keeps typos in *our* names an error. Swap 113 for an explicit read_globals list
-- if you ever want the API itself spell-checked.
ignore = {
    "113",  -- accessing undefined variable (WoW API)
    "212",  -- unused argument (event handlers)
    "213",  -- unused loop variable
}

globals = {
    "PoisonCheckDB",
    "SLASH_POISONCHECK1",
    "SLASH_POISONCHECK2",
    "SlashCmdList",
}
