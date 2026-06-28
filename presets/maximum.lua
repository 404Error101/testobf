-- presets/maximum.lua
-- Maximum obfuscation preset configuration
return {
  preset          = "maximum",
  renameVars      = true,
  encryptStrings  = true,
  obfuscateNumbers = true,
  injectJunk      = true,
  junkDensity     = 0.5,
  flattenFlow     = true,
  proxyGlobals    = true,
  wrapInFunction  = true,
  wrapLayers      = 3,
  minify          = false,
  renameGlobals   = false,
  preserve        = {},
}
