// Live game reads for the Rogue Dex: the same answers the Dex's /party, /battle, /run and /bag endpoints give, decoded
// from the emulator's own memory. Runs in JavaScriptCore inside the app (and under Node for tests).
//
// The host passes read(addr, size) -> Uint8Array, which throws for an address outside EWRAM/IWRAM. Each entry point
// returns [httpStatus, body]. Only what the game screen shows is emitted: enemy entries never carry exact stats, exact
// HP, held items, IVs/EVs, nature, or an ability or move that has not been revealed in battle.
//
// Memory layout (Emerald Rogue v2.2.1 EX, stock map):
//   gPlayerPartyCount 0x02036c79, gPlayerParty 0x02036c7c, struct Pokemon 104 B
//   gEnemyPartyCount 0x02036c7a, gEnemyParty 0x02036eec
//   gMain 0x030014b4 (.inBattle = bit 1 of byte +1081), gBattlersCount 0x0201c33c, gBattlerPartyIndexes 0x0201c340,
//   gBattleTypeFlags 0x0201c2c0, gBattleMons 0x0201c358 (96 B each), gBattleWeather 0x0201c768,
//   gBattleStruct* 0x0201c83c (->illusion[4] @660, 8 B each), gBattleResources* 0x0201c848 (->battleHistory* @32),
//   gFieldStatuses 0x0201c898, gRogueSaveBlock* 0x03003620 (->difficultyConfig.rangeValues @4396+3),
//   gSaveBlock1Ptr 0x03003614 (->flags @5328), gSaveBlock2Ptr 0x03003618 (->encryptionKey @76),
//   gRogueRun 0x02038334 (gimmick bits @2139), gBagPockets 0x02026524 (9 x {ItemSlot* @0, u8 capacity @4}),
//   gHealthboxSpriteIds 0x030022dc, gSprites 0x0203c690 (68 B each; battler @58, flags @62).
var RogueLive = (function () {
  "use strict";

  var PARTY_COUNT_ADDR = 0x02036C79, PARTY_ADDR = 0x02036C7C;
  var ENEMY_PARTY_COUNT_ADDR = 0x02036C7A, ENEMY_PARTY_ADDR = 0x02036EEC;
  var MON_SIZE = 104;
  var EWRAM_START = 0x02000000, EWRAM_SIZE = 0x40000, EWRAM_END = EWRAM_START + EWRAM_SIZE;

  var GMAIN_ADDR = 0x030014B4, GMAIN_IN_BATTLE_BYTE_OFFSET = 1081, GMAIN_IN_BATTLE_BIT = 0x02;
  var GBATTLERS_COUNT_ADDR = 0x0201C33C, GBATTLER_PARTY_INDEXES_ADDR = 0x0201C340;
  var GBATTLE_TYPE_FLAGS_ADDR = 0x0201C2C0, GBATTLE_MONS_ADDR = 0x0201C358, GBATTLE_WEATHER_ADDR = 0x0201C768;
  var GBATTLE_STRUCT_PTR_ADDR = 0x0201C83C, GBATTLE_RESOURCES_PTR_ADDR = 0x0201C848;
  var GFIELD_STATUSES_ADDR = 0x0201C898, GROGUE_SAVE_BLOCK_PTR_ADDR = 0x03003620;
  var BATTLE_MON_SIZE = 96, BATTLE_ILLUSION_OFFSET = 660;
  var BATTLE_RESOURCES_HISTORY_PTR_OFFSET = 32, BATTLE_HISTORY_SIZE = 92;
  var ROGUE_SAVE_DIFFICULTY_CONFIG_OFFSET = 4396, DIFFICULTY_RANGE_VALUES_OFFSET = 3;
  var POKEDEX_VARIANT_RANGE_INDEX = 4, BATTLE_FORMAT_RANGE_INDEX = 3;
  var POKEDEX_DYNAMIC_VARIANT_END = 40, POKEDEX_VARIANT_DEFAULT = 0;

  var GSAVEBLOCK1_PTR_ADDR = 0x03003614, GSAVEBLOCK2_PTR_ADDR = 0x03003618, GROGUE_RUN_ADDR = 0x02038334;
  var SAVEBLOCK1_FLAGS_OFFSET = 5328, FLAG_ROGUE_RUN_ACTIVE = 0x20;
  var ROGUE_RUN_GIMMICKS_OFFSET = 2139;
  var GBAG_POCKETS_ADDR = 0x02026524, BAG_POCKET_SIZE = 8, BAG_POCKET_CAPACITY_OFFSET = 4;
  var KEYITEMS_POCKET_INDEX = 8, ITEM_SLOT_SIZE = 4, SAVEBLOCK2_ENCRYPTION_KEY_OFFSET = 76;
  var ITEM_MEGA_RING = 714, ITEM_Z_POWER_RING = 715, ITEM_DYNAMAX_BAND = 716, ITEM_TERA_ORB = 783;
  var BAG_POCKET_COUNT = 9, BAG_ITEM_CAPACITY = 450, TMHM_POCKET_INDEX = 5;
  var BAG_ITEM_POCKETS = [0, 1, 2, 3, 6];
  var ITEM_TM01 = 593, ITEM_TM50 = 642, ITEM_HM01 = 693, ITEM_HM08 = 700, ITEM_TR01 = 933, ITEM_TR50 = 982;
  var MAX_BAG_ITEM_QUANTITY = 999;

  var BATTLE_TYPE_TRAINER = 1 << 3;
  var STATUS1_SLEEP_MASK = 0x7, STATUS1_POISON = 1 << 3, STATUS1_BURN = 1 << 4, STATUS1_FREEZE = 1 << 5;
  var STATUS1_PARALYSIS = 1 << 6, STATUS1_TOXIC_POISON = 1 << 7, STATUS2_TRANSFORMED = 1 << 21;
  var STATUS_FIELD_TRICK_ROOM = 1 << 1, DEFAULT_STAT_STAGE = 6, B_HEALTHBAR_PIXELS = 48;

  var GHEALTHBOX_SPRITE_IDS_ADDR = 0x030022DC, GSPRITES_ADDR = 0x0203C690, SPRITE_SIZE = 68;
  var SPRITE_BATTLER_OFFSET = 58, SPRITE_IN_USE = 0x1, SPRITE_INVISIBLE = 0x4, MAX_SPRITES = 64;

  // Substruct position for types 0-3 (growth, attacks, EVs, misc), indexed by personality % 24.
  var ORDER = [[0, 1, 2, 3], [0, 1, 3, 2], [0, 2, 1, 3], [0, 3, 1, 2], [0, 2, 3, 1], [0, 3, 2, 1], [1, 0, 2, 3],
    [1, 0, 3, 2], [2, 0, 1, 3], [3, 0, 1, 2], [2, 0, 3, 1], [3, 0, 2, 1], [1, 2, 0, 3], [1, 3, 0, 2], [2, 1, 0, 3],
    [3, 1, 0, 2], [2, 3, 0, 1], [3, 2, 0, 1], [1, 2, 3, 0], [1, 3, 2, 0], [2, 1, 3, 0], [3, 1, 2, 0], [2, 3, 1, 0],
    [3, 2, 1, 0]];

  // Per-device caches (the app has one device, but the shape follows the original service).
  var foundPartyAddr = {};     // status crc -> party address when the fixed one did not validate
  var revealedCache = {};      // battler -> last entry that was actually on screen
  var battleSignature = null;  // identity of the battle the cache belongs to

  function ReadError(message) { this.message = message; }

  // ---- byte helpers ----
  function u16(b, o) { return b[o] | (b[o + 1] << 8); }
  function s16(b, o) { var v = u16(b, o); return v >= 0x8000 ? v - 0x10000 : v; }
  function u32(b, o) { return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0; }
  function s8(v) { return v >= 0x80 ? v - 0x100 : v; }
  function hex(n) { return "0x" + n.toString(16); }
  function inEwram(addr) { return EWRAM_START <= addr && addr < EWRAM_END; }
  // Python's round(): halves go to the even neighbour.
  function pyRound(x) {
    var f = Math.floor(x), d = x - f;
    if (d > 0.5) return f + 1;
    if (d < 0.5) return f;
    return f % 2 === 0 ? f : f + 1;
  }

  function mk(read) {
    return {
      mem: function (addr, size) {
        var out = read(addr, size);
        if (!out || out.length !== size) throw new ReadError("no reply reading " + hex(addr));
        return out;
      },
      u8: function (addr) { return this.mem(addr, 1)[0]; },
      u16: function (addr) { return u16(this.mem(addr, 2), 0); },
      u32: function (addr) { return u32(this.mem(addr, 4), 0); }
    };
  }

  // ---- party ----
  function decodeMon(b) {
    var personality = u32(b, 0), otId = u32(b, 4);
    if (personality === 0 && otId === 0) return null;
    var flags = b[19];
    var key = (personality ^ otId) >>> 0;
    var secure = new Uint8Array(48);
    for (var i = 0; i < 12; i++) {
      var w = (u32(b, 32 + i * 4) ^ key) >>> 0;
      secure[i * 4] = w & 0xFF; secure[i * 4 + 1] = (w >>> 8) & 0xFF;
      secure[i * 4 + 2] = (w >>> 16) & 0xFF; secure[i * 4 + 3] = (w >>> 24) & 0xFF;
    }
    var sum = 0;
    for (var j = 0; j < 24; j++) sum += u16(secure, j * 2);
    if ((sum & 0xFFFF) !== u16(b, 28)) return { invalid: true };
    var order = ORDER[personality % 24];
    function sub(t) { return secure.subarray(order[t] * 12, order[t] * 12 + 12); }
    var g = u32(sub(0), 0);
    var misc = u32(sub(3), 8);
    var hp = u16(b, 86), maxHp = u16(b, 88), atk = u16(b, 90), dfn = u16(b, 92), spe = u16(b, 94);
    var spa = u16(b, 96), spd = u16(b, 98);
    var attacks = sub(1);
    return {
      species: g & 0x7FF,
      heldItem: ((g >>> 11) & 0x3FF) | (((g >>> 26) & 1) << 10),
      level: b[84],
      hp: hp,
      stats: [maxHp, atk, dfn, spa, spd, spe],
      moves: [u16(attacks, 0), u16(attacks, 2), u16(attacks, 4), u16(attacks, 6)],
      pp: [attacks[8], attacks[9], attacks[10], attacks[11]],
      ppBonuses: sub(0)[8],
      abilityNum: (misc >>> 29) & 3,
      nature: (personality % 25) ^ (b[18] >> 3),
      isEgg: Boolean((flags >> 2) & 1)
    };
  }

  function plausible(mon) {
    return Boolean(mon && !mon.invalid && mon.level >= 1 && mon.level <= 100 && mon.species > 0 &&
      mon.species < 2048 && mon.stats[0] > 0);
  }

  function partyAt(m, addr) {
    var count = m.mem(addr - 3, 1)[0];
    if (count < 1 || count > 6) return null;
    var blob = m.mem(addr, MON_SIZE * count);
    var mons = [];
    for (var i = 0; i < count; i++) mons.push(decodeMon(blob.subarray(i * MON_SIZE, (i + 1) * MON_SIZE)));
    return mons.every(plausible) ? mons : null;
  }

  function scanForParty(m) {
    var ram = m.mem(EWRAM_START, EWRAM_SIZE);
    for (var off = 4; off < ram.length - MON_SIZE; off += 4) {
      var count = ram[off - 3];
      if (count < 1 || count > 6 || off + MON_SIZE * count > ram.length) continue;
      var mons = [];
      for (var i = 0; i < count; i++) mons.push(decodeMon(ram.subarray(off + i * MON_SIZE, off + (i + 1) * MON_SIZE)));
      if (mons.every(plausible)) return [EWRAM_START + off, mons];
    }
    return [null, null];
  }

  function findPlayerParty(m, status) {
    var crc = status.indexOf("crc32=") >= 0 ? status.slice(status.lastIndexOf("crc32=") + 6) : status;
    var addr = foundPartyAddr.hasOwnProperty(crc) ? foundPartyAddr[crc] : PARTY_ADDR;
    var mons = partyAt(m, addr);
    if (mons === null) {
      var found = scanForParty(m);
      addr = found[0]; mons = found[1];
      if (mons !== null) foundPartyAddr[crc] = addr;
    }
    return [addr, mons];
  }

  // ---- battle ----
  function status1Name(s) {
    if (s & STATUS1_TOXIC_POISON) return "tox";
    if (s & STATUS1_POISON) return "psn";
    if (s & STATUS1_BURN) return "brn";
    if (s & STATUS1_FREEZE) return "frz";
    if (s & STATUS1_PARALYSIS) return "par";
    if (s & STATUS1_SLEEP_MASK) return "slp";
    return null;
  }

  function stagesDict(r) {
    return {
      atk: r[1] - DEFAULT_STAT_STAGE, def: r[2] - DEFAULT_STAT_STAGE, spe: r[3] - DEFAULT_STAT_STAGE,
      spa: r[4] - DEFAULT_STAT_STAGE, spd: r[5] - DEFAULT_STAT_STAGE, acc: r[6] - DEFAULT_STAT_STAGE,
      eva: r[7] - DEFAULT_STAT_STAGE
    };
  }

  // Quantized to the healthbar's pixel bucket: the screen never shows an enemy's exact fraction.
  function hpBarPct(hp, maxHp) {
    if (maxHp <= 0) return 0;
    if (hp >= maxHp) return 100;
    var frac = Math.floor(hp * B_HEALTHBAR_PIXELS / maxHp);
    if (frac === 0 && hp > 0) frac = 1;
    return pyRound(frac * 100 / B_HEALTHBAR_PIXELS);
  }

  function weatherName(bits) {
    if (bits & 0x0F) return "rain";
    if (bits & 0x30) return "sand";
    if (bits & 0x1C0) return "sun";
    if (bits & 0x600) return "hail";
    if (bits & 0x3000) return "snow";
    return null;
  }

  function terrainName(bits) {
    if (bits & 0x40) return "grassy";
    if (bits & 0x80) return "misty";
    if (bits & 0x100) return "electric";
    if (bits & 0x200) return "psychic";
    return null;
  }

  function decodeBattleMon(b) {
    var stages = [];
    for (var i = 0; i < 8; i++) stages.push(s8(b[24 + i]));
    return {
      species: u16(b, 0), moves: [u16(b, 12), u16(b, 14), u16(b, 16), u16(b, 18)], stagesRaw: stages,
      hp: u16(b, 42), level: b[44], maxHp: u16(b, 46), status1: u32(b, 80), status2: u32(b, 84),
      personality: u32(b, 76)   // identity check only, never emitted
    };
  }

  function readBattleRaw(m) {
    var inBattleByte = m.u8(GMAIN_ADDR + GMAIN_IN_BATTLE_BYTE_OFFSET);
    var inBattleBit = Boolean(inBattleByte & GMAIN_IN_BATTLE_BIT);
    var count = m.u8(GBATTLERS_COUNT_ADDR);
    var structPtr = m.u32(GBATTLE_STRUCT_PTR_ADDR);
    var resourcesPtr = m.u32(GBATTLE_RESOURCES_PTR_ADDR);
    var structOk = inEwram(structPtr), resourcesOk = inEwram(resourcesPtr);
    var valid = inBattleBit && (count === 2 || count === 4) && structOk && resourcesOk;
    return {
      valid: valid, count: count, structPtr: structPtr, resourcesPtr: resourcesPtr,
      debug: {
        gMainInBattleByte: inBattleByte, inBattleBit: inBattleBit, gBattlersCount: count,
        gBattleStructPtr: hex(structPtr), battleStructInEwram: structOk,
        gBattleResourcesPtr: hex(resourcesPtr), battleResourcesInEwram: resourcesOk, resolvedInBattle: valid
      }
    };
  }

  function healthboxStates(m, count) {
    var ids = m.mem(GHEALTHBOX_SPRITE_IDS_ADDR, 4);
    var states = [];
    for (var b = 0; b < count; b++) {
      var sid = ids[b];
      if (sid >= MAX_SPRITES) { states.push({ id: sid, owned: false, visible: false }); continue; }
      var blob = m.mem(GSPRITES_ADDR + sid * SPRITE_SIZE + SPRITE_BATTLER_OFFSET, 6);
      var owner = s16(blob, 0), flags = u16(blob, 4);
      var owned = Boolean(flags & SPRITE_IN_USE) && owner === b;
      states.push({ id: sid, owner: owner, owned: owned, visible: owned && !(flags & SPRITE_INVISIBLE) });
    }
    return states;
  }

  function gateOnScreen(entries, states) {
    var out = [];
    entries.forEach(function (entry) {
      var b = entry.battler;
      if (states[b].visible) {
        revealedCache[b] = entry;
        out.push(entry);
      } else if (revealedCache.hasOwnProperty(b)) {
        var copy = {};
        Object.keys(revealedCache[b]).forEach(function (k) { copy[k] = revealedCache[b][k]; });
        copy.hidden = true;
        out.push(copy);
      }
    });
    return out;
  }

  function buildBattleJson(m, raw) {
    var count = raw.count, structPtr = raw.structPtr, resPtr = raw.resourcesPtr;
    var typeFlags = m.u32(GBATTLE_TYPE_FLAGS_ADDR);
    var weatherBits = m.u16(GBATTLE_WEATHER_ADDR);
    var fieldBits = m.u32(GFIELD_STATUSES_ADDR);

    var ib = m.mem(structPtr + BATTLE_ILLUSION_OFFSET, 32);
    var illusions = [];
    for (var i = 0; i < 4; i++) illusions.push([ib[i * 8], ib[i * 8 + 1], ib[i * 8 + 2], ib[i * 8 + 3]]);

    var historyPtr = m.u32(resPtr + BATTLE_RESOURCES_HISTORY_PTR_OFFSET);
    var abilities = [0, 0, 0, 0], usedMoves = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
    if (inEwram(historyPtr)) {
      var h = m.mem(historyPtr, BATTLE_HISTORY_SIZE);
      abilities = [u16(h, 0), u16(h, 2), u16(h, 4), u16(h, 6)];
      for (var hb = 0; hb < 4; hb++) {
        var o = 12 + hb * 8;
        usedMoves[hb] = [u16(h, o), u16(h, o + 2), u16(h, o + 4), u16(h, o + 6)];
      }
    }

    var pi = m.mem(GBATTLER_PARTY_INDEXES_ADDR, count * 2);
    var partyIndexes = [];
    for (var p = 0; p < count; p++) partyIndexes.push(u16(pi, p * 2));
    var mb = m.mem(GBATTLE_MONS_ADDR, count * BATTLE_MON_SIZE);
    var battleMons = [];
    for (var bm = 0; bm < count; bm++) battleMons.push(decodeBattleMon(mb.subarray(bm * BATTLE_MON_SIZE, (bm + 1) * BATTLE_MON_SIZE)));

    var ecount = m.u8(ENEMY_PARTY_COUNT_ADDR);
    ecount = (ecount >= 0 && ecount <= 6) ? ecount : 0;
    var enemyPartyMons = [], eblob = null;
    if (ecount) {
      eblob = m.mem(ENEMY_PARTY_ADDR, MON_SIZE * ecount);
      for (var e = 0; e < ecount; e++) enemyPartyMons.push(decodeMon(eblob.subarray(e * MON_SIZE, (e + 1) * MON_SIZE)));
      // A new battle means a new enemy party: forget what the last battle revealed.
      var sig = [typeFlags];
      for (var s = 0; s < ecount; s++) sig.push(u32(eblob, s * MON_SIZE));
      var sigText = sig.join(",");
      if (battleSignature !== sigText) {
        battleSignature = sigText;
        revealedCache = {};
      }
    }
    var speciesLookup = {}, fainted = 0;
    enemyPartyMons.forEach(function (mon, idx) {
      if (mon && !mon.invalid) {
        speciesLookup[idx] = mon.species;
        if (mon.hp === 0) fainted++;
      }
    });

    var player = [], enemy = [];
    for (var b = 0; b < count; b++) {
      var mon = battleMons[b];
      if (b % 2 === 0) {
        player.push({
          battler: b, partyIndex: partyIndexes[b], speciesId: mon.species, level: mon.level, hp: mon.hp,
          maxHp: mon.maxHp, status: status1Name(mon.status1), stages: stagesDict(mon.stagesRaw), moves: mon.moves
        });
      } else {
        var il = illusions[b];
        var on = il[0], set = il[1], broken = il[2], partyId = il[3];
        var shown = (set && on && !broken) ?
          (speciesLookup.hasOwnProperty(partyId) ? speciesLookup[partyId] : mon.species) : mon.species;
        enemy.push({
          battler: b, speciesId: shown, level: mon.level, hpPct: hpBarPct(mon.hp, mon.maxHp),
          status: status1Name(mon.status1), stages: stagesDict(mon.stagesRaw), revealedAbility: abilities[b],
          revealedMoves: usedMoves[b].filter(function (x) { return x; }),
          transformed: Boolean(mon.status2 & STATUS2_TRANSFORMED)
        });
      }
    }

    var states = healthboxStates(m, count);
    // The AI copies party members into gBattleMons while it weighs a switch; a read mid-evaluation shows a Pokemon
    // that is not in battle. The real occupant has the personality of the party slot gBattlerPartyIndexes names.
    var enemyPids = {};
    for (var q = 0; q < ecount; q++) enemyPids[q] = u32(eblob, q * MON_SIZE);
    for (var c = 0; c < count; c++) {
      var idx = partyIndexes[c], expected = null;
      if (c % 2 === 0) expected = idx < 6 ? m.u32(PARTY_ADDR + idx * MON_SIZE) : null;
      else expected = enemyPids.hasOwnProperty(idx) ? enemyPids[idx] : null;
      var consistent = expected !== null && battleMons[c].personality === expected;
      states[c].consistent = consistent;
      if (!consistent) states[c].visible = false;
    }
    player = gateOnScreen(player, states);
    enemy = gateOnScreen(enemy, states);
    raw.debug.healthboxes = states;
    raw.debug.healthboxGate = true;

    return {
      inBattle: true, format: count === 4 ? "double" : "single", trainer: Boolean(typeFlags & BATTLE_TYPE_TRAINER),
      weather: weatherName(weatherBits), terrain: terrainName(fieldBits),
      trickRoom: Boolean(fieldBits & STATUS_FIELD_TRICK_ROOM), player: player, enemy: enemy,
      enemyParty: { count: ecount, fainted: fainted }
    };
  }

  // ---- run ----
  function readBattleFormat(m, roguePtr) {
    var raw = m.u8(roguePtr + ROGUE_SAVE_DIFFICULTY_CONFIG_OFFSET + DIFFICULTY_RANGE_VALUES_OFFSET + BATTLE_FORMAT_RANGE_INDEX);
    return (raw === 0 || raw === 1 || raw === 2) ? raw : null;
  }

  function readRunActive(m) {
    var sb1 = m.u32(GSAVEBLOCK1_PTR_ADDR);
    if (!inEwram(sb1)) return [null, null];
    var byte = m.u8(sb1 + SAVEBLOCK1_FLAGS_OFFSET + Math.floor(FLAG_ROGUE_RUN_ACTIVE / 8));
    return [Boolean(byte & (1 << (FLAG_ROGUE_RUN_ACTIVE % 8))), sb1];
  }

  function gimmicksFromRun(m) {
    var byte = m.u8(GROGUE_RUN_ADDR + ROGUE_RUN_GIMMICKS_OFFSET);
    return { mega: Boolean(byte & 1), z: Boolean(byte & 2), dynamax: Boolean(byte & 4), tera: Boolean(byte & 8) };
  }

  function gimmicksFromBag(m, sb1) {
    var pocket = GBAG_POCKETS_ADDR + KEYITEMS_POCKET_INDEX * BAG_POCKET_SIZE;
    var slots = m.u32(pocket);
    var cap = m.u8(pocket + BAG_POCKET_CAPACITY_OFFSET);
    var endOk = cap ? inEwram(slots + cap * ITEM_SLOT_SIZE - 1) : true;
    if (!inEwram(slots) || !endOk) return null;
    var found = {};
    found[ITEM_MEGA_RING] = false; found[ITEM_Z_POWER_RING] = false;
    found[ITEM_DYNAMAX_BAND] = false; found[ITEM_TERA_ORB] = false;
    if (cap) {
      var sb2 = m.u32(GSAVEBLOCK2_PTR_ADDR);
      if (!inEwram(sb2)) return null;
      var key = m.u32(sb2 + SAVEBLOCK2_ENCRYPTION_KEY_OFFSET) & 0xFFFF;
      var blob = m.mem(slots, cap * ITEM_SLOT_SIZE);
      for (var i = 0; i < cap; i++) {
        var id = u16(blob, i * 4), q = u16(blob, i * 4 + 2);
        if (found.hasOwnProperty(id) && (q ^ key) >= 1) found[id] = true;
      }
    }
    return { mega: found[ITEM_MEGA_RING], z: found[ITEM_Z_POWER_RING], dynamax: found[ITEM_DYNAMAX_BAND], tera: found[ITEM_TERA_ORB] };
  }

  // ---- bag ----
  function bagPocketTable(m) {
    var raw = m.mem(GBAG_POCKETS_ADDR, BAG_POCKET_COUNT * BAG_POCKET_SIZE);
    var table = [], any = false;
    for (var i = 0; i < BAG_POCKET_COUNT; i++) {
      var ptr = u32(raw, i * BAG_POCKET_SIZE), cap = raw[i * BAG_POCKET_SIZE + BAG_POCKET_CAPACITY_OFFSET];
      if (cap > BAG_ITEM_CAPACITY) return [null, raw];
      if (cap && !(inEwram(ptr) && inEwram(ptr + cap * ITEM_SLOT_SIZE - 1))) return [null, raw];
      table.push([ptr, cap]);
      if (cap) any = true;
    }
    return any ? [table, raw] : [null, raw];
  }

  function sameBytes(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  function readBagContents(m) {
    var sb2 = m.u32(GSAVEBLOCK2_PTR_ADDR);
    if (!inEwram(sb2)) return null;
    var t = bagPocketTable(m), table = t[0], rawTable = t[1];
    if (table === null) return null;
    var key = m.u32(sb2 + SAVEBLOCK2_ENCRYPTION_KEY_OFFSET) & 0xFFFF;
    var tms = {}, hms = {}, items = {}, trCount = 0;
    var pockets = [TMHM_POCKET_INDEX].concat(BAG_ITEM_POCKETS);
    for (var pi = 0; pi < pockets.length; pi++) {
      var pocket = pockets[pi], ptr = table[pocket][0], cap = table[pocket][1];
      if (!cap) continue;
      var blob = m.mem(ptr, cap * ITEM_SLOT_SIZE);
      for (var i = 0; i < cap; i++) {
        var id = u16(blob, i * 4), qty = u16(blob, i * 4 + 2) ^ key;
        if (id === 0) continue;
        if (qty > MAX_BAG_ITEM_QUANTITY) return null;
        if (qty === 0) continue;
        if (pocket === TMHM_POCKET_INDEX) {
          if (id >= ITEM_TM01 && id <= ITEM_TM50) tms[id - ITEM_TM01 + 1] = true;
          else if (id >= ITEM_HM01 && id <= ITEM_HM08) hms[id - ITEM_HM01 + 1] = true;
          else if (id >= ITEM_TR01 && id <= ITEM_TR50) trCount += qty;   // counted, never identified
        } else if (!(id >= ITEM_TR01 && id <= ITEM_TR50)) {
          items[id] = (items[id] || 0) + qty;
        }
      }
    }
    var again = bagPocketTable(m);
    if (!sameBytes(again[1], rawTable)) return null;   // an item changed mid-read
    function sortedKeys(o) { return Object.keys(o).map(Number).sort(function (a, b) { return a - b; }); }
    var itemsOut = {};
    sortedKeys(items).forEach(function (k) { itemsOut[String(k)] = items[k]; });
    return { tms: sortedKeys(tms), hms: sortedKeys(hms), trCount: trCount, items: itemsOut };
  }

  // ---- entry points: [status, body] ----
  function guard(fn) {
    try {
      return fn();
    } catch (err) {
      if (err instanceof ReadError) return [502, { error: "The game refused the read: " + err.message + "." }];
      return [500, { error: String(err && err.stack || err) }];
    }
  }

  function party(read, ctx) {
    return guard(function () {
      var m = mk(read);
      var found = findPlayerParty(m, ctx.status);
      if (found[1] === null) {
        return [422, { error: "Connected, but no valid party was found in memory (still on the title screen?).",
          device: ctx.device, devices: ctx.devices }];
      }
      return [200, { device: ctx.device, name: ctx.name, status: ctx.status, address: hex(found[0]), party: found[1],
        devices: ctx.devices, readAt: ctx.readAt, readAtMs: ctx.nowMs }];
    });
  }

  function battle(read, ctx, debug) {
    return guard(function () {
      var m = mk(read);
      var raw = readBattleRaw(m);
      var body;
      if (!raw.valid) {
        revealedCache = {};   // a new battle starts with nothing revealed
        var f = findPlayerParty(m, ctx.status);
        body = { inBattle: false, device: ctx.device, name: ctx.name, party: f[1] || [], readAtMs: ctx.nowMs };
        if (debug) body.debug = raw.debug;
        return [200, body];
      }
      body = buildBattleJson(m, raw);
      body.party = findPlayerParty(m, ctx.status)[1] || [];
      body.device = ctx.device; body.name = ctx.name; body.readAtMs = ctx.nowMs;
      if (debug) body.debug = raw.debug;
      return [200, body];
    });
  }

  function run(read, ctx) {
    return guard(function () {
      var m = mk(read);
      var body = { dexVariant: null, battleFormat: null, gimmicks: null, runActive: null, device: ctx.device,
        name: ctx.name, readAtMs: ctx.nowMs };
      var roguePtr = m.u32(GROGUE_SAVE_BLOCK_PTR_ADDR);
      if (inEwram(roguePtr)) {
        var rawVariant = m.u8(roguePtr + ROGUE_SAVE_DIFFICULTY_CONFIG_OFFSET + DIFFICULTY_RANGE_VALUES_OFFSET + POKEDEX_VARIANT_RANGE_INDEX);
        body.dexVariant = rawVariant <= POKEDEX_DYNAMIC_VARIANT_END ? rawVariant : POKEDEX_VARIANT_DEFAULT;
        body.battleFormat = readBattleFormat(m, roguePtr);
      } else {
        body.error = "save data isn't loaded yet (title screen?)";
      }
      var ra = readRunActive(m);
      body.runActive = ra[0];
      body.gimmicks = ra[0] === null ? null : (ra[0] ? gimmicksFromRun(m) : gimmicksFromBag(m, ra[1]));
      return [200, body];
    });
  }

  function bag(read, ctx) {
    return guard(function () {
      var m = mk(read);
      var body = { tms: null, hms: null, trCount: null, items: null, device: ctx.device, name: ctx.name,
        readAtMs: ctx.nowMs };
      var b = readBagContents(m);
      if (b === null) {
        body.error = "bag isn't readable yet (title screen, or an item changed mid-read)";
      } else {
        body.tms = b.tms; body.hms = b.hms; body.trCount = b.trCount; body.items = b.items;
      }
      return [200, body];
    });
  }

  function reset() { foundPartyAddr = {}; revealedCache = {}; battleSignature = null; }

  return { party: party, battle: battle, run: run, bag: bag, reset: reset, _hpBarPct: hpBarPct };
})();

if (typeof module !== "undefined") module.exports = RogueLive;
