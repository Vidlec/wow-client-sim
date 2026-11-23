// The game's fonts are plain TrueType/OpenType files in CASC (Fonts\FRIZQT__.TTF and the like).

/** The first four bytes of a font file: TrueType 1.0, OpenType (CFF), Apple TrueType, a TrueType collection */
export const FONT_MAGICS: readonly string[] = ["\x00\x01\x00\x00", "OTTO", "true", "ttcf"];

export const isFont = (data: Uint8Array): boolean =>
  data.length >= 4 && FONT_MAGICS.includes(String.fromCharCode(data[0] ?? 0, data[1] ?? 0, data[2] ?? 0, data[3] ?? 0));
