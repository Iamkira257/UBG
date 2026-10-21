--============================================================================
--  v5 2026-10-20  -  what changed, and the measurement behind each one
--
--  1. THE DASH KEY IS READ, NOT ASSUMED. Build 4 pressed Space. The game's own
--     keybind widget reads Dash=X on this account (LightAttack=K, HeavyAttack=L,
--     Block=F), so every Space press went to a key the game does not bind. That
--     is the whole explanation for "6 of 25 registered": it was not timing, it
--     was a dead key. _G.D.key() prints what was read; cfg.dodgeKey is only the
--     fallback when the widget cannot be read.
--
--  2. FEINTS ARE DETECTED BY SOUND. Measured live by diffing Workspace.Debris
--     every 15ms: a feint writes Feint + Feint2 + FeintRustle into Debris.
--     SoundPart ~50ms after the attempt, while the IsFeinting stamp this file
--     used to veto on is written 330-400ms after it. ~300ms earlier, no clock
--     needed. Nothing on a Sound is readable here except Name/ClassName/Parent/
--     Address, so a cue is a NEW INSTANCE tracked by Address.
--
--  3. A FEINT IS ANSWERED WITH A PUNCH. A fake has no hitbox, so dodging it is
--     the fake paying off. The counter presses the light attack (K, read from
--     the same widget) into the recovery the fake leaves behind, twice if the
--     first produces no impact sound, and the game's own <me>Hit sound is what
--     says COUNTER LANDED. One fake gets one answer: the sound and the stamp
--     are the same attempt, so the stamp is ignored for feintOnceMs after a
--     counter (measured live: without that, one fake cost four punches).
--
--  4. The dodge is held off for the rest of the fake (counterHoldOffMs) so the
--     repeat press does not spend 12 stamina on the fake the counter saved; the
--     hold ends early on the real punch's own Swing sound.
--============================================================================
--  BOXING DODGE  v2   -   Untitled Boxing Game        rewrite  2026-10-18
--  console only, no GUI.  Supersedes dodge.lua (restarts 1-25) and the probe
--  half of boxing.lua.  _G.D is the whole interface.
--
--============================================================================
--  WHY A REWRITE INSTEAD OF RESTART 26
--
--  Restarts 1-25 are 5,600 lines of patches, and most of that length is the
--  archaeology of things that were wrong: four versions of the stun gate, a
--  fist detector that was allowed to steer the key and then was not, a second
--  and third press path bolted on when the first one was blamed, an offset
--  sweep that mistimed dodges on purpose. Every one of those has a measured
--  answer now. The behaviour they were reaching for is small; the history is
--  what is big. So this file keeps the ANSWERS and throws away the branches.
--
--  The biggest structural change: an exchange is one linear function again.
--  Restarts 13-25 ran each punch in its own thread with cancellation, a
--  re-dodge queue and three ways to withhold a press - and the reported bugs
--  are exactly the bugs that structure produces (a window re-armed while the
--  old one was still measuring, a second press arriving after the hit, two
--  predicates disagreeing about one flag). Here a punch is read, a fuse is
--  waited out, a key goes down, Space is tapped, the game is asked whether it
--  registered, the landing is scored - in that order, in one function. A token
--  that arrives mid-fuse re-arms THAT window rather than opening a second one.
--  A token that arrives after the press ends the scoring window early
--  (RE-TARGET) so the loop arms it on the next tick - a blocking 1200ms landing
--  watch would otherwise arm the next dodge a second late, which is exactly
--  what the re-dodge queue was built around.
--
--============================================================================
--  WHAT v2 CAN DO THAT dodge.lua COULD NOT
--
--  A rewrite has to be better, not just shorter. Six things here are new
--  behaviour, not tidied-up behaviour:
--
--  1. THE FUSE IS A WINDOW, AND IT HAS TWO SIDES. A dash has to be UP before
--     the punch lands and its i-frames still running when it does:
--         press + latency            <  landing - margin   (up in time)
--         press + latency + iframes  >  landing            (not spent yet)
--     so the press window is [landing - latency - iframes, landing - latency -
--     margin] and the fuse aims at its middle. The old rule could only move
--     EARLIER, because the logs only ever showed the late half of the error -
--     which meant it could walk straight past the early half (the double-token
--     and the heavy windup) without ever noticing. This one moves both ways
--     and logs the arithmetic it moved on.
--
--  2. THE LATENCY IS MEASURED. Every registration stamps press -> the game's
--     own LastDashTime, and the median replaces dashUpMs=120 in the arithmetic
--     above. One number that was a constant is now an instrument.
--
--  3. THE HEAVY FUSE IS PER OPPONENT, learned from their heavy landings. A flat
--     +50ms was measured wrong on one opponent (its heavies landed like its
--     lights) and right on another (a ~900ms charged M2). Now each one gets
--     its own window, and the +50ms is only the starting guess.
--
--  4. THE DIRECTION HAS A SCOREBOARD AND CAN SWITCH ITSELF. needed / mapping /
--     fist are scored by outcome with the same discipline the old sweep lock
--     used: >=8 judged, >=3 perfects, and a 3-perfect lead before the default
--     changes. dirAB() used to make the player run that experiment by hand.
--
--  5. THE FIST IS A TIEBREAKER, NOT A STEER. It is consulted only when the
--     game publishes no NeededDirection for the attack, it is scored in its
--     own group, and it switches itself off when it is not winning. The old
--     fistSwap moved the key 35 times on one opponent and every swap turned a
--     correct dodge into a wrong one.
--
--  6. TIMING IS IN EVERY ALIVE REPORT: median press offset, measured latency,
--     and the three direction groups, so a fight is diagnosable without a
--     transcript.
--
--============================================================================
--  THE FACTS THIS IS BUILT ON (each one measured in a live run, not assumed)
--
--  OPPONENT   workspace.States.<you>.CharacterData.Opponent   (ObjectValue)
--             A distance fallback exists for the frames before that is written.
--
--  ATTACK     TryAttack is a token that CHANGES per attempt and is cleared
--             between punches. IsHeavy is a real bool. AttackingHand persists,
--             so it is read at the moment the token changes.
--
--  DASH       The game keeps its own ledger on your character:
--               LastDashTime         when the game last logged a dash
--               LocalCompensatedTime the client's view of that clock
--               TimeBetweenDash      the gap between the last two dashes
--               DashSpamLevel        0 after a dash, ~0.95 on a refused press
--               NeededDirection      the side the game expected, for this attack
--               CachedDashDirection  what the game actually recorded
--               LastPerfectDodged    when it last scored a perfect
--               DashInvulnerable     when the current i-frames began
--             LastDashTime MOVING is the authoritative "that press dashed".
--             A stamina drop of 3+ and a direction change are the backups,
--             because a perfect dodge does not always pulse Dashing.
--
--  GATE       Refusals are the game's, not the input's: presses 636ms and
--             1219ms after a dash were refused, every press at 1566ms or more
--             registered, and the game's own TimeBetweenDash read 1.467s and
--             1.55s. minDashGapMs=1400 sits inside that bracket. A refused
--             press costs no stamina - so it is cheap - but it has no i-frames,
--             and the punch it was aimed at lands. The refusal IS the hit.
--             DashSpamLevel is spent at 1.0, not 3: 0.95 buys a refusal.
--
--  STUN       Stunned is a LATCH in a real fight, not a live state: 150 reads
--             carried an age 0.73..5.65s PAST the flag's own StunnedUntil
--             (median 2.69s). Restart 24 withheld 99 of 158 presses on it and
--             the withheld windows took 3 hits; the 22 presses it let through
--             with the flag up registered 12 (55%) against 28 of 37 (76%) with
--             it clear. So a flag refuses only while StunnedUntil is genuinely
--             AHEAD on the server clock. One function, stunVerdict(), answers
--             for the gate, the press, the retry and the cover dash.
--
--  DIRECTION  NeededDirection at the ARM is always the punching hand's own
--             side (28 of 28 steered presses) and the game overwrites it for
--             the attack in flight; at press time it names the side AWAY from
--             the fist on 37 of 46 presses. Splitting three groups by damage:
--               pressed the mapping (away from the fist)  6 PERFECT  5 HIT
--               pressed the arm-time value, it HELD        1 PERFECT  4 HIT
--               pressed the arm-time value, it FLIPPED     2 PERFECT 10 HIT
--             Pressing the side the game asked for registered a dash 53-68% of
--             the time and scored 27 perfects; the other side 12-23% and one.
--             So the base side is the mapping (handMap + dirRule="into"), and
--             the game may MOVE the key any time it says left/right - changed
--             value or not. That is checked continuously through the pre-hold.
--
--  FUSE       fireMs is ms from the attack token to the Space press. The dash
--             needs ~120ms to come up and a press wins when it lands ~80ms
--             before the punch: against the fast opponent their winning
--             punches land at 324ms median, which is why one global fuse was
--             too late. Per opponent, fuse = median(their landings) - 120 - 80,
--             clamped to [feintGuardMs, fireMs] - a one-directional rule,
--             because the buffer shows the late half of the error and not one
--             press that was too early. Pressing early on a feint is the trap.
--
--  FEINT      IsFeinting is written at +3..+7ms of the token; the real punch
--             behind a fake arrives 0.25..0.33s later. So a stamp younger than
--             0.35s cancels the dodge and keeps the stamina, and the follow-up
--             token then arms a normal window like any other punch (giving the
--             follow-up a SHORT fuse pressed 24-56ms before its token existed,
--             which is the restart-13 bug the live log caught).
--             ConfirmedFeintRequestId arrives +175..757ms late - counted, not
--             used to gate, because it is usually after the press.
--
--  HEAVY      The charged M2 winds up ~900ms and lands at +884..+915ms of its
--             token, long after the first dash's 300ms of i-frames. But one
--             opponent threw heavies that landed at +322..+393ms, the same as
--             its lights - so the +50ms heavy fuse is only applied once THIS
--             opponent's heavies are measured landing later than its lights.
--             The cover dash at +600ms is the other half of the answer.
--
--  PERFECT    No damage taken AND PerfectDodgeMeter jumping within 450ms of
--             the press (a real perfect showed +232..+314ms; later meter
--             movement is the charge cycle). Meter movement alone is never
--             called a perfect.
--
--  HIT        Health going down. Not a timestamp: LastDamaged and LastStunned
--             came back "not a server time" on every measured hit.
--
--  INPUT      keypress(0x20) is the shape that has worked, with
--             VirtualInputManager:SendKeyEvent as the other candidate. "The
--             call did not error" is NOT evidence the key arrived: restart 14
--             sent four keydowns on one key in one frame and the game dropped
--             the dash. One shape, one press, and the client's own
--             UserInputService is the judge (_G.D.keytest()).
--
--  WHAT THIS EXECUTOR CANNOT DO, so nothing here pretends otherwise:
--    * No heap scans and no getgc. A 150k-instance map plus repeated getgc
--      sweeps is what crashed the client once; this script reads about a dozen
--      attributes per tick and nothing else.
--    * Instance.new is not available, so no attachment, part or event can be
--      built from here.
--    * Several properties are unbound (Attachment.WorldPosition reads nil).
--      _G.D.caps() lists which reads actually work before you trust a feature.
--    * Remotes are a LOCAL STUB in this executor: InvokeServer returns true
--      regardless of the argument and never reaches the server, on five
--      different calls including getters that must return data. So there is no
--      "fire the dash remote" route in this file. If the press dies, the
--      answer is the press, not a remote.
--
--============================================================================
--  WHAT THIS DROPPED FROM THE OLD FILES, AND WHY
--    * the GUI lab (boxing.lua's 40 dump commands). Useful to build the map
--      once; _G.D.dump() prints the part of it that a dodge needs.
--    * route()/fire()/remote(). A stub channel is not a fallback, it is a way
--      to spend a fight proving nothing.
--    * the animation fingerprint. AnimationId is not readable in this VM and
--      GetPlayingAnimationTracks is not a bound method, so anim=nil was never
--      a bug to fix.
--    * the offset sweep. It mistimed dodges on purpose and its auto-lock was
--      never separated from noise; the per-opponent fuse measures the same
--      thing from landings that actually happened.
--    * fist steering. The vote ran L0 R2 / L0 R3 on an opponent throwing
--      LeftHand and every swap turned a correct dodge into a wrong one. The
--      geometry is still MEASURED and printed (fistFrame="count") so the log
--      can settle into/away; it does not move the key.
--
--============================================================================
--  USING IT
--    _G.D.status()            counters, the gate, the current fuse
--    _G.D.set("fireMs", 150)  every setting is live
--    _G.D.show()              the tunables and their current values
--    _G.D.keys(80)            the tail of the transcript
--    _G.D.copy()              the whole run to the clipboard (and a file)
--    _G.D.stun()              the raw stun state and the one verdict
--    _G.D.side("LeftHand")    which key the next press would use, and why
--    _G.D.dir("left")         one manual dodge, to test the mapping by hand
--    _G.D.presstest()         one Space press, judged by the game's ledger
--    _G.D.spam()              DashSpamLevel seen at presses and registrations
--    _G.D.hl()                the startup-highlight clock: edges, the learned
--                             delay, the token lag, and ShinyStartups
--    _G.D.land()              per-opponent landing offsets and the fuse they imply
--    _G.D.dump()              opponent + own attributes, one screen
--    _G.D.caps()              what this build can read and press
--    _G.D.build()             which copy of this file is loaded
--    _G.D.rink()              am I on a canvas, and which one
--    _G.D.feint()             the feint stamps, the patience and the clock
--    _G.D.keytest()           one tap per shape; the CLIENT says if it arrived
--    _G.D.release()           let go of every key (a stuck key swallows dashes)
--    _G.D.on() .off() .stop()
--
--  HOW TO READ THE LOG - one exchange, in order:
--    ATTEMPT   their punch, the hand, and the side this will press
--    NEEDED    the game named the other side and the held key moved
--    FEINT     the game's own stamp, younger than 0.35s: DODGE CANCELLED
--    SKIP      a real reason not to press (live stun / mid-dash / stamina /
--              spam / the game's inter-dash gap). Not a failure - the game
--              refusing, caught before it costs the window.
--    DODGE     the keys went out. over= is ms past the fuse, gap= is ms since
--              the previous press, stam= and spam= are the game's numbers.
--    REGISTERED / NOT REGISTERED   the game's own ledger answering
--    DIR       the settled CachedDashDirection against the side that was wanted
--    PERFECT / HIT / CLEAN     the outcome. HIT says how long after the press
--              it landed and whether the dash was ever up.
--
--============================================================================

-- let go of anything the previous build left down, then stop it
pcall(function()
	local old = _G.D
	if old and type(old.release) == "function" then old.release() end
end)
pcall(function()
	local old = _G.D
	if old and type(old.stop) == "function" then old.stop() end
end)
pcall(function()
	local old = _G.PD
	if old and type(old.stop) == "function" then old.stop() end
end)
pcall(function()
	local old = _G.BX
	if old and type(old.stop) == "function" then old.stop() end
end)

--=============================== SETTINGS ===================================
-- every number here was measured; every one is live through _G.D.set()
local cfg = {
	auto            = true,
	-- THE DASH KEY, READ OUT OF THE GAME. It was assumed to be Space for three
	-- builds; on 2026-10-20 the game's own keybind widget (PlayerGui.Common.
	-- Keybinds ... Dash.Press.Key) read X, so every press this file sent was
	-- going to a key the game does not bind. readKeybinds=true reads it at boot
	-- and _G.D.key() prints what it found; this default is only the fallback.
	dodgeKey        = "X",
	readKeybinds    = true,
	keybindRetryMs  = 4000,
	forwardKey      = "W",
	leftKey         = "A",
	rightKey        = "D",
	backKey         = "S",

	-- press shape. "single" sends cfg.pressShape; keytest() proves which shape
	-- the client takes and writes the answer into cfg.pressLock.
	pressMode       = "single",
	pressShape      = "vk",
	pressLock       = nil,
	-- THE KEY TEST DASHES FOUR TIMES IN A ROW WITH NOBODY PUNCHING AT YOU.
	-- That is the loudest thing this file can do, and it fires 1.5s after every
	-- load - including a load taken while standing outside the ropes. The
	-- decisive question is answered by _G.D.presstest() on demand instead, which
	-- presses once and asks the GAME. Set autoKeyTest=true to get it back.
	autoKeyTest     = false,
	keyTestAtMs     = 1500,
	tryVim          = true,

	-- ONLY IN THE RINK. The game keeps the opponent locked on and keeps
	-- publishing punch tokens while this character stands outside the ropes
	-- watching, so "an opponent exists" was never the same question as "am I in
	-- the fight" - and the old gate asked the first one. The press now waits for
	-- the canvas, read from workspace.Rings (see inRink()).
	requireRink     = true,
	rinkMargin      = 3,     -- studs of slack around the canvas edge
	-- the canvas is 8.9 studs thick and the floor is not at the character's
	-- height, so the vertical window is generous on purpose
	rinkYSlack      = 12,
	rinkCacheMs     = 2000,  -- rescan workspace.Rings this often

	-- direction, in order of trust: the held key is pushed down early, the game
	-- may move it any time it publishes left/right, and it is released shortly
	-- after the press so a bare Space cannot be read as "no direction held".
	preholdMs       = 140,   -- 80 was not enough: the game kept a STALE direction
	pressHoldMs     = 40,    -- how long Space is held down
	dirReleaseMs    = 60,    -- keep the direction key down this long past the press
	dirRule         = "into",   -- the key goes to the side the fist is COMING FROM
	handMap         = { LeftHand = "left", RightHand = "right" },
	dirSource       = "needed", -- needed | auto
	neededPoll      = true,
	neededPollMs    = 12,
	fistFrame       = "count",  -- count | off   (never steers)
	dirFistFallback = "auto",   -- auto | off   the fist names the side ONLY when
	                            -- the game names none, and switches itself off
	                            -- when its own scoreboard says it is losing
	dirAuto         = true,     -- may the scoreboard change the default side?
	                            -- >=8 judged, >=3 perfects, 3-perfect lead
	spinMs          = 25,

	-- the fuse
	fireMs          = 170,
	minFireMs       = 100,
	maxFireMs       = 560,
	fusePerOpp      = true,
	fusePerOppMin   = 3,
	dashUpMs        = 120,
	coverMarginMs   = 80,
	feintGuardMs    = 165,

	-- THE STARTUP HIGHLIGHT. The game parents a Highlight named
	-- StartupHighlight into the welded copy of every rig
	-- (Workspace.Welds.<name>.WeldCharacter) for the attack itself, and it is
	-- and Workspace.Settings.ShinyStartups is the setting it is named after -
	-- but measured on a live server it kept appearing with that setting OFF, so
	-- it is reported and never used as a gate. It is a plain "does this child
	-- exist" check, it is published at the attack, and it is what the short
	-- script in the wild presses on - which is why that script beats this file
	-- on timing with twenty lines. The edge is now the clock, its delay is
	-- learned from this opponent's own landings, and the feint veto this file
	-- already had still runs before the press (the short script has no feint
	-- tell, which is its only weakness).
	startupClock    = true,  -- false = the token clock only
	-- WHICH ENGINE PRESSES. "startup" is the one the measurements chose: the
	-- edge, a bare Space, and another press every 350ms while the highlight is
	-- still up - which is what the short script in the wild does every loop,
	-- and is why it recovers from a refused press instead of losing the window.
	-- It has no dash-gap gate, because a refused press costs 1 stamina of 100
	-- (measured: 81.19 -> 80.19) while a WITHHELD press costs the whole attack:
	-- v3 withheld 8 windows and registered 6 of 25; the bare engine below
	-- registered 5 of 7 in the same client, mid-fight. "fuse" is the old
	-- measured-window engine, kept whole and still selectable.
	engine          = "startup",  -- startup | fuse
	startupRepeatMs = 350,   -- while the highlight is up, press again no sooner
	startupHoldMs   = 100,   -- the short script holds Space 100ms
	startupMs       = 250,   -- the short script's own delay: the default until
	                         -- this opponent has landed on the startup clock
	startupMinMs    = 120,
	startupMaxMs    = 460,
	startupAdoptMs  = 140,   -- a token this soon after the edge is the SAME
	                         -- attack arriving late, not a new window

	-- heavies
	heavyExtraMs    = 50,
	heavyLateGapMs  = 60,
	heavyCover      = true,
	heavyCoverAtMs  = 600,
	heavyCoverPreholdMs = 110,

	-- the second press when the first one produced nothing. A refused press
	-- costs no stamina, and the log has one retry that scored PERFECT.
	retryAfterMs    = 120,
	retryMax        = 1,

	-- feints
	antiFeint       = true,
	feintStamp      = true,
	feintLiveS      = 0.35,
	-- THE SMIDGE. Against an opponent that has feinted at least once this
	-- session, the press waits this long past the fuse before it commits - a
	-- fake that is still winding up gets that much more time to show itself.
	-- It is cut back automatically when their measured landing says the wait
	-- would put the press too late to matter (the log says when and why).
	feintPatienceMs = 25,

	-- SOUND. Measured live on 2026-10-20 by diffing Workspace.Debris every 15ms
	-- through a real 1v1 on this build:
	--   attack start  Debris.<name>Start exists, then <name>Start/Step ~50ms
	--                 AFTER the attempt, Swing/SwingBig ~130ms after it
	--   landing       <name>Hit/Hit1 | Heavy1 | Crush | GuardHit
	--   FEINT         Feint + Feint2 + FeintRustle land in Debris.SoundPart in
	--                 the same 50ms, ~50ms after the fake started, and ~370ms
	--                 BEFORE the real punch behind it
	-- So the feint SOUND is a tell ~300ms earlier than the IsFeinting stamp
	-- (measured 330-400ms late), and it needs no clock. Only existence, Name,
	-- ClassName and Address are readable on a Sound here - Playing, SoundId and
	-- TimeLength all read nil - so a cue is a NEW INSTANCE in Debris, tracked by
	-- Address, because two reads of one instance never compare equal.
	soundCues       = true,
	soundFeintWindowMs = 700,  -- how long a feint cue stays actionable
	-- A cue is only believed when an ATTACK TOKEN changed just before it. The
	-- reason is measured: the game re-creates Debris.SoundPart now and then, and
	-- whatever feint sounds were still parented to it turn up as "new" again -
	-- two of those landed 947ms after an attack edge in a live fight. A real cue
	-- is written ~50ms after its own token, so this window is generous.
	soundFeintTokenMs = 320,
	-- ...and the cue has to belong to THAT token: a cue older than the token by
	-- more than this is from the attempt before it. Measured live: a replayed
	-- cue 543ms old got credited to a token that changed 274ms later.
	soundFeintLeadMs = 120,

	-- COUNTER-PUNCH. A feint has no hitbox, so the correct answer to one is not
	-- a dodge (a dodge is what the fake was asking for) - it is a punch, thrown
	-- into the recovery the fake leaves behind. The light attack is bound to K
	-- in the same keybind widget the dash key was read from.
	counter         = true,
	counterKey      = "K",
	counterHoldMs   = 55,
	counterSecondMs = 170,  -- second punch if the first produced no hit sound
	counterWatchMs  = 520,  -- how long the game's hit sound is watched for
	-- A counter must not be followed by a dodge of the SAME fake: the highlight
	-- stays up through the feint, so the engine would otherwise press on it
	-- 110ms later and spend the dodge the counter just saved. This holds the
	-- dodge off for the rest of that attempt; a real punch behind the fake is a
	-- NEW edge and starts its own clock. Measured gap from the fake to the real
	-- punch: 370ms.
	counterHoldOffMs = 1200,
	-- ONE FAKE, ONE ANSWER, and this is the window that decides it. The sound
	-- cue and the IsFeinting stamp describe the same attempt 300-400ms apart, so
	-- without this a single fake got FOUR punches in a live fight (25.80s sound,
	-- 26.16s stamp, two each).
	feintOnceMs     = 1200,

	-- when NOT to dodge
	minStamina      = 12,
	maxSpamLevel    = nil,  -- OFF. This build's DashSpamLevel is NOT 0..1: it
	                        -- was read at 2.54 one instant after a PERFECT
	                        -- registered, so a 0.5 ceiling skips everything.
	                        -- _G.D.spam() reports the range seen at presses and
	                        -- at registrations; set the number from that.
	minDashGapMs    = 1400,
	stalePairMs     = 1000,
	-- OFF BY DEFAULT, and that is a live measurement rather than a shrug. In the
	-- current build Stunned is set often with StunnedUntil genuinely AHEAD, and
	-- the old gate spent whole windows on "stun held for 260ms and did not
	-- clear" - a withheld press buys nothing, while a refused one costs no
	-- stamina and 55% of the presses sent with the flag up registered a dash.
	-- Presses made with the flag set are counted as stale= in the status.
	-- auto: trust Stunned only while StunnedUntil is ahead; flag: Stunned alone
	-- refuses; off: stun never withholds a press.
	stunGate        = "off",   -- auto | flag | off
	stunWaitMs      = 0,     -- 0 = do not wait out a stun; press on the fuse
	skipStunned     = true,
	maxDist         = 12,

	-- timing
	pollMs          = 25,
	confirmMs       = 500,
	dirSettleMs     = 200,
	iframeMs        = 300,
	perfectWindowMs = 450,
	exchangeMs      = 1200,
	statusMs        = 20000,

	-- transcript
	watchKeys       = true,
	watchLines      = 6000,
	copyLines       = 1200,

	verbose         = true,
}

-- THE BUILD STAMP. Three copies of this file exist at any moment - the one on
-- disk, the one a chat window rendered, and the one an executor is running -
-- and "Matcha:638: attempt to call a nil value" is indistinguishable between
-- them. _G.D.build() answers which one is loaded, so a line number in an error
-- can be matched to the right source instead of guessed at.
local BUILD = "v5.0 2026-10-20 sound feint -> counter-punch, dash key read from the game"

-- keypress shapes. vk is the shape that has worked; Enum/lower/upper are tried
-- by keytest() because a build can accept exactly one of them.
local VK = {
	Space = 0x20, W = 0x57, A = 0x41, S = 0x53, D = 0x44,
	Shift = 0x10, LeftShift = 0x10, Q = 0x51, E = 0x45, F = 0x46, R = 0x52,
	-- X is the game's DASH and K is its LIGHT ATTACK (both read from the
	-- keybind widget, not guessed). A key missing from this table is a press
	-- that fails at argFor() and is counted as INPUT.failed - which is exactly
	-- what happened to every press while dash was assumed to be Space.
	X = 0x58, K = 0x4B, L = 0x4C, C = 0x43, V = 0x56, G = 0x47, Z = 0x5A,
}
local FORMS = { "Enum", "lower", "upper", "vk" }
local STATES = "States"
local DATA = "CharacterData"

--=========================== TRANSCRIPT / LOG ===============================
-- One buffer holds every line this script prints and every key edge it sees,
-- so _G.D.copy() hands over a whole fight instead of a scrolled console.
local WATCH = { n = 0, lines = {}, paused = false, keys = 0, dup = 0,
	lastCode = nil, lastAt = nil, mine = nil, real = {}, sent = {} }

local function clock()
	if os and type(os.clock) == "function" then return os.clock() end
	return 0
end
local t0 = clock()
local function now() return clock() - t0 end

local function wrecord(line)
	if WATCH.paused then return end
	WATCH.lines[#WATCH.lines + 1] = line
	while #WATCH.lines > cfg.watchLines do table.remove(WATCH.lines, 1) end
	WATCH.n = #WATCH.lines
end

local function log(msg)
	local line = string.format("[D %7.2fs] %s", now(), msg)
	print(line)
	wrecord(line)
end

local function warn(msg)
	local line = string.format("[D %7.2fs] !! %s", now(), msg)
	print(line)
	wrecord(line)
end

--=============================== UTIL ======================================
local function safe(obj, key)
	if obj == nil then return nil end
	local ok, v = pcall(function() return obj[key] end)
	if ok then return v end
	return nil
end

-- an attribute read that reports whether it worked. nil + false is "this build
-- does not expose it", nil + true is "exposed but empty" - a distinction the
-- stun verdict and the ledger both depend on.
local function attr(inst, name)
	if inst == nil then return nil, false end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if not ok then return nil, false end
	return v, true
end

-- SERVICES, NOT GLOBALS. This executor has no `Players` global at all - it
-- reads nil - while game:GetService("Players") and game.Players both work. A
-- bare `Players` reference here was the whole reason nothing happened live:
-- lp() returned nil, the name was nil, no opponent was ever found.
local function service(name)
	local ok, s = pcall(function() return game:GetService(name) end)
	if ok and s ~= nil then return s end
	local ok2, s2 = pcall(function() return game[name] end)
	if ok2 then return s2 end
	return nil
end
local PLR = service("Players")

local function nameOf(inst)
	return tostring(safe(inst, "Name") or "?")
end

local function num(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then
		local n = tonumber(v)
		if n ~= nil then return n end
	end
	return nil
end

local function clamp(v, lo, hi)
	if v == nil then return nil end
	if lo ~= nil and v < lo then v = lo end
	if hi ~= nil and v > hi then v = hi end
	return v
end

local function medianOf(list)
	if list == nil or #list == 0 then return nil end
	local copy = {}
	for i = 1, #list do copy[i] = list[i] end
	table.sort(copy)
	local mid = math.floor((#copy + 1) / 2)
	return copy[mid]
end

local function posOf(inst)
	if inst == nil then return nil end
	local ok, p = pcall(function() return inst.Position end)
	if not ok or p == nil then return nil end
	local x, y, z = num(safe(p, "X")), num(safe(p, "Y")), num(safe(p, "Z"))
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

local function rootOf(model)
	if model == nil then return nil end
	local r = nil
	pcall(function() r = model:FindFirstChild("HumanoidRootPart") end)
	if r ~= nil then return r end
	return safe(model, "PrimaryPart")
end

local function dist(a, b)
	if a == nil or b == nil then return nil end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--============================== CAPABILITIES ===============================
-- Nothing below is assumed. The executor this was built against has keypress
-- but no Instance, no heap scan and a stubbed remote layer, and a build can
-- differ, so the boot prints what exists before a fight is spent on it.
local ENV = { keypress = nil, keyrelease = nil, uis = nil, vim = nil,
	enum = false, setclipboard = nil, writefile = nil, shape = nil }

local function capsProbe()
	pcall(function() ENV.keypress = _G.keypress end)
	pcall(function() ENV.keyrelease = _G.keyrelease end)
	if type(ENV.keypress) ~= "function" then ENV.keypress = nil end
	if type(ENV.keyrelease) ~= "function" then ENV.keyrelease = nil end
	pcall(function() ENV.setclipboard = _G.setclipboard or _G.toclipboard end)
	pcall(function() ENV.writefile = _G.writefile end)
	pcall(function() ENV.enum = Enum ~= nil and Enum.KeyCode ~= nil end)
	local ok, svc = pcall(function() return game:GetService("VirtualInputManager") end)
	if ok and svc ~= nil then
		local ok2, fn = pcall(function() return svc.SendKeyEvent end)
		if ok2 and type(fn) == "function" then ENV.vim = svc end
	end
	local ok3, uis = pcall(function() return game:GetService("UserInputService") end)
	if ok3 then ENV.uis = uis end
	-- the read that proves a character is reachable at all
	ENV.players = PLR ~= nil
	local ok4, ch = pcall(function() return PLR.LocalPlayer.Character end)
	ENV.characterReadable = ok4 and (ch ~= nil)
	return ENV
end

local function capsLine()
	return string.format("keypress=%s keyrelease=%s vim=%s UIS=%s Players=%s Enum=%s clipboard=%s writefile=%s shape=%s",
		ENV.keypress and "yes" or "NO", ENV.keyrelease and "yes" or "NO",
		ENV.vim and "yes" or "no", ENV.uis and "yes" or "NO",
		ENV.players and "yes" or "NO",
		ENV.enum and "yes" or "no",
		ENV.setclipboard and "yes" or "no", ENV.writefile and "yes" or "no",
		tostring(ENV.shape or cfg.pressShape))
end

--================================ INPUT ====================================
local INPUT = { sent = 0, failed = 0, held = {}, state = "unproven",
	lock = nil, arrivals = { sent = 0, real = 0, dup = 0 }, verdict = "not tested" }

local function argFor(name, form)
	if form == "Enum" then
		local ok, kc = pcall(function() return Enum.KeyCode[name] end)
		if ok and kc ~= nil then return kc end
		return nil
	end
	if form == "lower" then return string.lower(name) end
	if form == "upper" then return string.upper(name) end
	if form == "vk" then return VK[name] end
	return nil
end

local function sendVim(name, down)
	if cfg.tryVim ~= true or ENV.vim == nil then return false end
	local ok, kc = pcall(function() return Enum.KeyCode[name] end)
	if not ok or kc == nil then return false end
	local good = pcall(function() ENV.vim:SendKeyEvent(down and true or false, kc, false) end)
	return good
end

-- ONE shape per press. cfg.pressLock is written by keytest(); pressShape is the
-- incumbent until something proves otherwise.
local function shapeNow()
	if cfg.pressLock ~= nil then return cfg.pressLock end
	if cfg.pressMode == "single" or cfg.pressMode == "all" then return cfg.pressShape end
	return cfg.pressMode
end

local function press(name, down, tag)
	if name == nil then return false end
	local shape = shapeNow()
	if shape == "vim" then
		local ok = sendVim(name, down)
		if not ok then
			INPUT.failed = INPUT.failed + 1
			return false
		end
	else
		local fn = down and ENV.keypress or ENV.keyrelease
		if fn == nil then
			INPUT.failed = INPUT.failed + 1
			return false
		end
		local arg = argFor(name, shape)
		if arg == nil then
			INPUT.failed = INPUT.failed + 1
			return false
		end
		local ok = pcall(fn, arg)
		if not ok then
			INPUT.failed = INPUT.failed + 1
			return false
		end
	end
	INPUT.sent = INPUT.sent + 1
	if down then INPUT.held[name] = true else INPUT.held[name] = nil end
	wrecord(string.format("[D %7.2fs] SEND  %s %-3s [%s/%s]", now(),
		down and "down" or "up", name, tostring(tag or "-"), shape))
	return true
end

local function releaseAll()
	local names = {}
	for n in pairs(INPUT.held) do names[#names + 1] = n end
	for i = 1, #names do press(names[i], false, "release") end
end

-- hold the key down for holdMs using a spin, because task.wait quantises to
-- ~17ms and the whole perfect window is only a few multiples of that.
local function tapFor(name, holdMs)
	press(name, true, "tap")
	local until_ = now() + (holdMs / 1000)
	while now() < until_ do end
	press(name, false, "tap")
end

local function keySnap()
	local out = {}
	for _, k in ipairs({ "forwardKey", "leftKey", "rightKey", "backKey", "dodgeKey" }) do
		out[#out + 1] = string.format("%s=%s", cfg[k], (INPUT.held[cfg[k]] and "DOWN") or "-")
	end
	return table.concat(out, " ")
end

--============================= KEY TEST ====================================
-- The press question, asked at the client instead of at the rink: one tap per
-- shape, and UserInputService says whether the key ARRIVED. No dash, no
-- opponent, no stamina - one second instead of a lost fight.
local function keyTestListen()
	if ENV.uis == nil then return false end
	if WATCH.keyListen then return true end
	WATCH.keyListen = true
	local function edge(input)
		pcall(function()
			local at = now()
			local kc = input.KeyCode
			local nm = nil
			pcall(function() nm = kc.Name end)
			local code = nm and tostring(nm) or tostring(kc)
			local who = WATCH.mine
			local row = string.format("[D %7.2fs] KEY   %-4s %s%s", at,
				input.UserInputState and tostring(input.UserInputState) or "?",
				code, who and ("  <- " .. who) or "  <- REAL")
			wrecord(row)
			if who ~= nil then
				WATCH.sent[#WATCH.sent + 1] = { shape = who, code = code, at = at }
				if WATCH.lastCode == code and WATCH.lastAt ~= nil and (at - WATCH.lastAt) < 0.004 then
					WATCH.dup = WATCH.dup + 1
				end
				WATCH.lastCode, WATCH.lastAt = code, at
			else
				WATCH.real[#WATCH.real + 1] = { code = code, at = at }
			end
		end)
	end
	local ok1 = pcall(function() ENV.uis.InputBegan:Connect(edge) end)
	local ok2 = pcall(function() ENV.uis.InputEnded:Connect(edge) end)
	return ok1 and ok2
end

local function keytest(quiet)
	if not keyTestListen() then
		warn("UserInputService cannot be listened to in this build - the press cannot be verified from here")
		INPUT.verdict = "unverified: no UIS"
		return nil
	end
	if cfg.dodgeKey == nil then return nil end
	if not quiet then
		log("KEY TEST - one tap per shape, no dash. KEEP HANDS OFF THE KEYBOARD: a Space you press would be credited to whichever shape is running.")
	end
	local winner = nil
	for _, form in ipairs(FORMS) do
		if winner == nil then
			local arg = argFor(cfg.dodgeKey, form)
			local before = #WATCH.sent
			if arg ~= nil and ENV.keypress ~= nil then
				WATCH.mine = form
				local sent = pcall(ENV.keypress, arg)
				local held = now() + 0.03
				while now() < held do end
				pcall(ENV.keyrelease, arg)
				local settle = now() + 0.12
				while now() < settle do end
				WATCH.mine = nil
				local arrived = 0
				for i = before + 1, #WATCH.sent do arrived = arrived + 1 end
				if arrived > 0 then winner = form end
				if not quiet then
					local note
					if not sent then
						note = "REJECTED by this build (wrong argument type for keypress)"
					elseif arrived > 0 then
						note = "ARRIVED at the client"
					else
						note = "sent, but the client did not report it"
					end
					log(string.format("  shape %-6s %s", form, note))
				end
			end
		end
	end
	if winner ~= nil then
		cfg.pressLock = winner
		ENV.shape = winner
		INPUT.state = "working"
		INPUT.verdict = "the press is ALIVE - " .. winner .. " reaches the client's UserInputService"
		log(string.format("KEY TEST: the press is ALIVE. '%s' alone is locked in, and every press in this file now goes out through it.", winner))
		return winner
	end
	-- the vim shape is separate: it needs no keypress and takes an Enum
	if cfg.tryVim and ENV.vim ~= nil then
		local before = #WATCH.sent
		WATCH.mine = "vim"
		sendVim(cfg.dodgeKey, true)
		local held = now() + 0.03
		while now() < held do end
		sendVim(cfg.dodgeKey, false)
		local settle = now() + 0.12
		while now() < settle do end
		WATCH.mine = nil
		if #WATCH.sent > before then
			cfg.pressLock, ENV.shape, INPUT.state = "vim", "vim", "working"
			INPUT.verdict = "the press is ALIVE through VirtualInputManager"
			log("KEY TEST: the press is ALIVE through VirtualInputManager")
			return "vim"
		end
	end
	INPUT.state = "unverified"
	INPUT.verdict = "no injected key was reported by UserInputService - INCONCLUSIVE. This build's keypress takes a virtual key code (an Enum is rejected), and the client need not report injected keys. _G.D.presstest() answers it with the game's own ledger instead."
	warn("KEY TEST: no injected key showed up in UserInputService - and that is NOT proof the press is dead here. The client does not have to report injected keys.")
	warn("  the decisive question is answered by the GAME: _G.D.presstest() presses Space once and checks LastDashTime. If it moves, the press works regardless of what this test saw.")
	return nil
end

--============================= GAME STATE ==================================
local cache = {}
local WORLD = { opp = nil, oppModel = nil, tok = nil, lastFallback = 0 }

-- declared up here, not in the measurement section, because the stun gate and
-- the loop both read it and a local declared FURTHER DOWN is not an upvalue of
-- a function written above it - the reference silently becomes a GLOBAL and
-- throws at runtime. Restart 2 lost a whole session to exactly that shape.
local counters = {
	exchanges = 0, presses = 0, registered = 0, unregistered = 0,
	perfect = 0, hit = 0, clean = 0, late = 0, skipped = 0,
	feint = 0, feintLate = 0, rearm = 0, cover = 0, retry = 0,
	hlPress = 0, feintHl = 0,
	-- feints caught by each tell, and the punches thrown instead of a dodge
	feintSound = 0, feintStamp = 0,
	counter = 0, counterHit = 0, counterMiss = 0,
	dirOk = 0, dirBad = 0, dirUnknown = 0, neededUsed = 0, neededMoved = 0,
	stunWait = 0, stunHeld = 0, staleStun = 0, stalePress = 0,
	-- presses NOT sent because this character is not on the canvas
	rinkSkip = 0,
	-- exchanges that waited feintPatienceMs longer than the fuse
	feintWait = 0,
	frameInto = { n = 0, p = 0, h = 0 }, frameAway = { n = 0, p = 0, h = 0 },
	poff = {},
}

-- ONE FAKE, ONE ANSWER. The sound cue and the IsFeinting stamp describe the SAME
-- attempt 300ms apart, so without this the file throws four punches at one fake:
-- measured live at 25.80s (sound) and 26.16s (stamp), both counting. ANSWERED.at
-- is when a counter last went out; a stamp inside the hold is the same fake
-- arriving late, not a second one.
local ANSWERED = { at = nil, skips = 0 }

local function lp()
	if PLR == nil then return nil end
	local ok, p = pcall(function() return PLR.LocalPlayer end)
	if ok then return p end
	return nil
end

--========================= THE REAL KEYBINDS ===============================
-- This file guessed its keys for three builds and guessed wrong. The game
-- publishes your actual binds in its own keybind widget, and they are plain
-- TextLabels - readable here - so the keys are READ:
--
--   PlayerGui.Common.Keybinds.Main.Scroll.Controls.Keybinds.<Action>.Press.Key
--
-- Measured on this account 2026-10-20: Dash=X, LightAttack=K, HeavyAttack=L,
-- Block=F, Ultimate=Q, Special=R, QuickStep=LeftShift. Space was bound to
-- nothing, so every "bare Space" press in build 4 was sent to a dead key - the
-- registrations that did happen were the game reading a different input path,
-- and that is why the numbers never held up.
local KEYS = { dash = nil, light = nil, heavy = nil, block = nil, quick = nil,
	from = "cfg default", at = nil, read = 0 }

local function keybindText(action)
	local p = lp()
	if p == nil then return nil end
	local pg = nil
	pcall(function() pg = p:FindFirstChild("PlayerGui") end)
	if pg == nil then return nil end
	local node = pg
	for _, step in ipairs({ "Common", "Keybinds", "Main", "Scroll", "Controls", "Keybinds", action, "Press", "Key" }) do
		if node == nil then return nil end
		local nxt = nil
		pcall(function() nxt = node:FindFirstChild(step) end)
		node = nxt
	end
	if node == nil then return nil end
	local text = nil
	pcall(function() text = node.Text end)
	if type(text) ~= "string" then return nil end
	text = string.gsub(text, "%s", "")
	if #text == 0 or #text > 12 then return nil end
	-- Shift is one key with two names, and VK only has one of them
	if text == "LeftShift" or text == "RightShift" then return "Shift" end
	if #text == 1 then return string.upper(text) end
	return text
end

local function readKeybinds(quiet)
	KEYS.at = now()
	local dash, light = keybindText("Dash"), keybindText("LightAttack")
	local got = 0
	if dash ~= nil and VK[dash] ~= nil then
		KEYS.dash, KEYS.from, got = dash, "the game's keybind widget", got + 1
		cfg.dodgeKey = dash
	elseif dash ~= nil then
		if not quiet then
			log(string.format("KEYBINDS: Dash is bound to %s, which this file has no virtual key code for - keeping %s. _G.D.caps() lists what it sends.", dash, tostring(cfg.dodgeKey)))
		end
	end
	if light ~= nil and VK[light] ~= nil then
		KEYS.light, cfg.counterKey = light, light
		got = got + 1
	end
	KEYS.heavy = keybindText("HeavyAttack")
	KEYS.block = keybindText("Block")
	KEYS.quick = keybindText("QuickStep")
	KEYS.read = got
	if not quiet and got > 0 then
		log(string.format("KEYBINDS read from the game: dash=%s counter=%s heavy=%s block=%s. These are the keys the presses use - nothing here is assumed any more.",
			tostring(cfg.dodgeKey), tostring(cfg.counterKey), tostring(KEYS.heavy or "?"), tostring(KEYS.block or "?")))
	end
	return got
end

local function myName()
	local p = lp()
	if p == nil then return nil end
	return tostring(safe(p, "Name") or "?")
end

local function myModel()
	local p = lp()
	if p == nil then return nil end
	return safe(p, "Character")
end

local function dataOf(name)
	if name == nil then return nil end
	local held = cache[name]
	if held ~= nil and safe(held, "Parent") ~= nil then return held end
	local root = nil
	pcall(function() root = workspace.States end)
	if root == nil then pcall(function() root = workspace:FindFirstChild(STATES) end) end
	if root == nil then return nil end
	local row = nil
	pcall(function() row = root:FindFirstChild(name) end)
	if row == nil then return nil end
	local data = nil
	pcall(function() data = row:FindFirstChild(DATA) end)
	if data ~= nil then cache[name] = data end
	return data
end

local function valueOf(name, field)
	local data = dataOf(name)
	if data == nil then return nil end
	local v = nil
	pcall(function() v = data:FindFirstChild(field) end)
	if v == nil then return nil end
	return safe(v, "Value")
end

-- the game's own answer to "who am I fighting"
local function opponentModel()
	local n = myName()
	if n == nil then return nil end
	local data = dataOf(n)
	if data == nil then return nil end
	local v = nil
	pcall(function() v = data:FindFirstChild("Opponent") end)
	if v == nil then return nil end
	return safe(v, "Value")
end

local function health()
	local n = myName()
	local v = num(valueOf(n, "Health"))
	if v ~= nil then return v end
	local hum = safe(myModel(), "Humanoid")
	if hum == nil then
		pcall(function() hum = myModel():FindFirstChildOfClass("Humanoid") end)
	end
	if hum == nil then return nil end
	local ok, h = pcall(function() return hum.Health end)
	if ok then return num(h) end
	return nil
end

local function stamina()
	return num(valueOf(myName(), "Stamina"))
end

local function meter()
	return num(valueOf(myName(), "PerfectDodgeMeter"))
end

local function dashing()
	return valueOf(myName(), "Dashing") == true
end

-- The Opponent value is the authority. The distance fallback only exists for
-- the frames after a rig appears and before the game writes it, and it is
-- re-scanned at most twice a second - a GetPlayers() copy on every 25ms tick is
-- exactly the kind of work this rewrite is trying not to do.
-- The state row carries an Occupied folder beside CharacterData, and its
-- LockedOn ObjectValue names the rig you are locked onto. Read live, LockedOn
-- gave the model plainly while CharacterData.Opponent came back unreadable.
local function occupiedRow()
	local data = dataOf(myName())
	if data == nil then return nil end
	local row = safe(data, "Parent")
	if row == nil then return nil end
	local occ = nil
	pcall(function() occ = row:FindFirstChild("Occupied") end)
	return occ
end

local function lockTarget()
	local occ = occupiedRow()
	if occ == nil then return nil end
	local v = nil
	pcall(function() v = occ:FindFirstChild("LockedOn") end)
	if v == nil then return nil end
	local t = safe(v, "Value")
	if t == nil then return nil end
	if safe(t, "Parent") == nil then return nil end
	return t
end

local function findOpponent()
	local live = lockTarget()
	if live ~= nil then
		return { model = live, name = nameOf(live), how = "LockedOn",
			dist = dist(posOf(rootOf(myModel())), posOf(rootOf(live))) }
	end
	local om = opponentModel()
	if om ~= nil and safe(om, "Parent") ~= nil then
		return { model = om, name = nameOf(om), how = "Opponent",
			dist = dist(posOf(rootOf(myModel())), posOf(rootOf(om))) }
	end
	if (now() - WORLD.lastFallback) < 0.5 then return nil end
	WORLD.lastFallback = now()
	local mine = posOf(rootOf(myModel()))
	if mine == nil then return nil end
	if PLR == nil then return nil end
	local ok, list = pcall(function() return PLR:GetPlayers() end)
	if not ok or type(list) ~= "table" then return nil end
	local p = lp()
	local best = nil
	for _, other in ipairs(list) do
		if other ~= p then
			local ch = safe(other, "Character")
			local op = posOf(rootOf(ch))
			local d = dist(mine, op)
			if ch ~= nil and d ~= nil and d <= cfg.maxDist and (best == nil or d < best.dist) then
				best = { model = ch, name = nameOf(ch), dist = d, how = "distance" }
			end
		end
	end
	return best
end

local function refresh()
	local opp = findOpponent()
	WORLD.opp = opp
	if opp ~= nil then
		if WORLD.oppModel ~= opp.model then
			-- a new rig: nothing about the old one carries over, and the token
			-- that is there on the first read is a LIVE attack, not a baseline
			WORLD.oppModel = opp.model
			WORLD.tok = nil
			log(string.format("FOE %s (%s)%s", opp.name, opp.how,
				opp.dist and string.format(" dist=%.1f", opp.dist) or ""))
		end
	else
		WORLD.oppModel = nil
		WORLD.tok = nil
	end
	return opp
end

--======================== THE STARTUP HIGHLIGHT ============================
-- The game's own marker for "an attack has started": a Highlight named
-- StartupHighlight, parented into the welded copy of the rig for as long as the
-- swing runs (measured at 570-680ms on a live server), created only while
-- Workspace.Settings.ShinyStartups is on. None of its properties are readable in
-- this executor - only that it exists - and that is enough: the EDGE is the
-- clock, and what the attempt really is gets decided by the attributes this
-- file already reads.
--
-- Measured on the live server while writing this: the edge lands within one poll
-- of TryAttack (the token changed with the highlight on the same tick in 10 of
-- 12 edges), so this is not an earlier signal so much as an earlier CLOCK - the
-- exists-check is the cheapest read available, so the window starts before the
-- twelve attribute reads the token path needs, instead of after them. That is
-- the fifty milliseconds the log kept finding between the fuse and the press.
local HL = { rig = nil, rigName = nil, on = false, at = nil, seen = 0,
	fire = {}, lead = {}, setting = nil, settingAt = nil }

local function hlSetting()
	if HL.settingAt ~= nil and (now() - HL.settingAt) < 5 then return HL.setting end
	HL.settingAt = now()
	local v = nil
	pcall(function()
		local ws = workspace
		local folder = ws and ws:FindFirstChild("Settings")
		local flag = folder and folder:FindFirstChild("ShinyStartups")
		if flag ~= nil then v = safe(flag, "Value") end
	end)
	HL.setting = v
	return v
end

-- the rig the game parents the highlight into. Cached per opponent name: the
-- weld row is stable for a whole fight, so this is one FindFirstChild per fight
-- after the first tick.
local function hlRigFor(model, name)
	if name == nil then return nil end
	if HL.rigName == name and HL.rig ~= nil and safe(HL.rig, "Parent") ~= nil then
		return HL.rig
	end
	local rig = nil
	pcall(function()
		local ws = workspace
		local folder = ws and ws:FindFirstChild("Welds")
		local row = folder and folder:FindFirstChild(name)
		rig = row and row:FindFirstChild("WeldCharacter")
	end)
	if rig ~= nil then
		HL.rig, HL.rigName = rig, name
	end
	return rig
end

local function hlUp(opp)
	local rig = hlRigFor(opp and opp.model, opp and opp.name)
	if rig == nil then return false end
	local sh = nil
	pcall(function() sh = rig:FindFirstChild("StartupHighlight") end)
	return sh ~= nil
end

-- the rising edge, and the clock. The highlight stays up for the whole swing,
-- so a second punch thrown while it is still up is the TOKEN's job - this fires
-- once per attack, not once per frame.
local function hlEdge(opp)
	local up = hlUp(opp)
	if up and not HL.on then
		HL.on, HL.at = true, now()
		HL.seen = HL.seen + 1
		return HL.at
	end
	if (not up) and HL.on then HL.on = false end
	return nil
end

-- how late the token was behind the edge. Only used for the report - the clock
-- never waits for the token.
local function noteLead(ms)
	if ms == nil or ms < 0 or ms > 400 then return end
	HL.lead[#HL.lead + 1] = ms
	while #HL.lead > 12 do table.remove(HL.lead, 1) end
end

local function hlLine()
	local fire = medianOf(HL.fire)
	local lead = medianOf(HL.lead)
	return string.format("startup highlight: ShinyStartups=%s rig=%s up=%s edges=%d presses=%d feint-cancels=%d delay=%s lead=%s",
		tostring(hlSetting()), tostring(HL.rigName or "-"), tostring(HL.on),
		HL.seen, counters.hlPress, counters.feintHl,
		fire and string.format("%.0fms (n=%d)", fire, #HL.fire) or ("default " .. cfg.startupMs .. "ms"),
		lead and string.format("%.0fms (n=%d)", lead, #HL.lead) or "unmeasured")
end

--======================== SOUND: THE GAME'S OWN CUES =======================
-- Measured live on 2026-10-20 by diffing Workspace.Debris every 15ms through a
-- real 1v1 on this build. What the game actually creates, and when:
--
--   [1.50s] Axel_2576Start/Step                 my attack, 50ms after it began
--   [1.63s] Axel_2576Start/SwingBig             130ms after it began
--   [1.77s] Axel_2576Hit/Crush + HeavyLayer + SurgeonHeadHit   my heavy LANDED
--   [6.30s] victor64_BStart/Step                their attack began
--   [6.35s] SoundPart/Feint + Feint2 + FeintRustle   THEIR ATTEMPT WAS A FAKE
--   [6.72s] victor64_BStart/Step                the real punch behind it
--   [6.83s] victor64_BStart/SwingBig             ...and it swung 480ms after the fake
--
-- That is the whole reason for this section: the feint cue is ~50ms after the
-- attempt, while IsFeinting - the tell build 4 vetoed on - is written 330-400ms
-- after it (measured, and it is exactly what a feint is built to exploit).
-- Sound is therefore the earliest feint tell this file has, and it needs no
-- clock, no token and no highlight.
--
-- The constraint that shapes the code: on this executor NOTHING on a Sound is
-- readable except Name, ClassName, Parent and Address. .Playing, .TimeLength
-- and .SoundId all read nil (checked). So a cue is a NEW INSTANCE appearing in
-- Debris, not a playback state - and instances are tracked by Address, because
-- two reads of the same instance do not compare equal but their addresses do.
local SND_FEINT_CUE = { Feint = true, Feint2 = true, FeintRustle = true }
local SND_HIT_CUE = { Hit1 = true, Heavy1 = true, Crush = true, GuardHit = true,
	Counter = true, FastHit = true, SharpHit = true, HitLayer = true }
local SND_SWING_CUE = { Swing = true, SwingBig = true, Step = true }

-- the attempt clock the sound cue is judged against. Separate from WORLD.tok
-- on purpose: the fuse engine consumes that one to decide its own windows, and
-- writing it from the tick would eat the change it is waiting for.
local TOKN = { v = nil, at = nil }

local SND = {
	root = nil, seen = {}, primed = false, cues = {}, n = 0,
	stale = 0,
	feints = 0, swings = 0, hits = 0, steps = 0, scans = 0,
	lastFeintAt = nil, lastFeintName = nil, claimed = nil,
	lastSwingAt = nil, lastOppHitAt = nil, lastMyHitAt = nil,
	lastCounterCueAt = nil, lastCounterAt = nil,
	counterLanded = 0, counterMissed = 0,
}

local function sndDebris()
	local d = SND.root
	if d ~= nil and safe(d, "Parent") ~= nil then return d end
	d = nil
	pcall(function()
		local ws = workspace
		if ws ~= nil then d = ws:FindFirstChild("Debris") end
	end)
	SND.root = d
	return d
end

-- one cue, with the only attribution available: the container's own name.
-- "<opponent>Start" / "<opponent>Hit" are theirs, "<me>Start" are mine, and
-- SoundPart is the shared one the game uses for feints, steps and counter hits.
local function sndCue(name, holder, owner)
	if type(name) ~= "string" then return end
	local at = now()
	SND.n = SND.n + 1
	SND.cues[#SND.cues + 1] = { n = name, h = holder, o = owner, t = at }
	while #SND.cues > 40 do table.remove(SND.cues, 1) end
	if SND_FEINT_CUE[name] == true and owner ~= "me" then
		SND.feints = SND.feints + 1
		SND.lastFeintAt, SND.lastFeintName = at, name
		-- one line per fake, not one per cue: the game writes three of them on
		-- the same tick
		if name == "Feint" then
			-- only the fresh ones are worth a line. The game re-creates
			-- Debris.SoundPart and replays its leftover Feint children as "new"
			-- instances; those arrive seconds after any token and are counted,
			-- not printed (measured at 947ms, 2008ms and 4932ms after the token).
			local tokAge = TOKN.at and (at - TOKN.at) or nil
			if tokAge ~= nil and tokAge >= 0 and tokAge <= (cfg.soundFeintTokenMs / 1000) then
				log(string.format("SOUND %s/%s - THE FEINT CUE, %.0fms after the attack token. The stamp this file used to wait for lands 330-400ms late; this is the same news ~300ms earlier.",
					holder, name, tokAge * 1000))
			else
				SND.stale = SND.stale + 1
			end
		end
		return
	end
	if SND_HIT_CUE[name] == true then
		SND.hits = SND.hits + 1
		if owner == "me" then
			SND.lastMyHitAt = at
		elseif owner == "opp" then
			SND.lastOppHitAt = at
		elseif name == "Counter" then
			SND.lastCounterCueAt = at
		end
		return
	end
	if SND_SWING_CUE[name] == true and owner == "opp" then
		SND.swings = SND.swings + 1
		SND.lastSwingAt = at
	end
end

-- the poll. Costs one GetChildren on Debris plus one on the three or four
-- containers that can hold a sound this tick - not a tree walk, and not one
-- GetChildren per part in the map.
local function sndPoll(oppName)
	if cfg.soundCues ~= true then return end
	local root = sndDebris()
	if root == nil then return end
	local kids = nil
	if not pcall(function() kids = root:GetChildren() end) or kids == nil then return end
	local mine = myName()
	local nextSeen = {}
	for i = 1, #kids do
		local c = kids[i]
		local cname = safe(c, "Name")
		if type(cname) ~= "string" then cname = "?" end
		local ca = safe(c, "Address")
		local ckey = ca and tostring(ca) or ("?" .. i)
		nextSeen[ckey] = true
		-- only the containers that carry sounds in the measurement
		local scan = (string.sub(cname, -5) == "Start")
			or (string.sub(cname, -3) == "Hit")
			or (cname == "SoundPart")
		if scan then
			local owner = "other"
			if oppName ~= nil and string.find(cname, oppName, 1, true) ~= nil then
				owner = "opp"
			elseif mine ~= nil and string.find(cname, mine, 1, true) ~= nil then
				owner = "me"
			elseif cname == "SoundPart" then
				owner = "shared"
			end
			local sub = nil
			if pcall(function() sub = c:GetChildren() end) and sub ~= nil then
				for j = 1, #sub do
					local s = sub[j]
					if safe(s, "ClassName") == "Sound" then
						local sa = safe(s, "Address")
						local sk = sa and tostring(sa) or (ckey .. "/" .. j)
						nextSeen[sk] = true
						if SND.seen[sk] ~= true then
							-- "shared" is passed as "?": the feint cue has no owner
							-- in its name, so whether it is theirs is decided by the
							-- attack edge it arrives on (see soundFeint)
							sndCue(tostring(safe(s, "Name")), cname, (owner == "shared") and "?" or owner)
						end
					end
				end
			end
		end
	end
	SND.seen = nextSeen
	SND.scans = SND.scans + 1
	SND.primed = true
end

-- Is the feint cue live, and does it belong to an attack that is actually
-- running? The cue is written ~50ms after the attempt, so the highlight is up
-- in the measured case; the 150ms grace exists for the frames where it is not.
local function soundFeint()
	if cfg.soundCues ~= true then return nil end
	local at = SND.lastFeintAt
	if at == nil then return nil end
	local age = now() - at
	if age < 0 or age > (cfg.soundFeintWindowMs / 1000) then return nil end
	if SND.claimed == at then return nil end
	-- an attack token has to have moved just before the cue. Without this, a
	-- re-created Debris.SoundPart replays its leftover Feint children as new
	-- cues long after the attack they belonged to (measured: 947ms and 1924ms).
	local fresh = nil
	local tokAge = (TOKN.at ~= nil) and (now() - TOKN.at) or nil
	if tokAge ~= nil then
		fresh = (tokAge >= 0 and tokAge <= (cfg.soundFeintTokenMs / 1000))
		-- the cue comes ~50ms AFTER its own token (measured), so one that is
		-- older than the token by more than the tolerance is a replay
		if fresh and (age - tokAge) > (cfg.soundFeintLeadMs / 1000) then fresh = false end
	else
		fresh = HL.on or age <= 0.15
	end
	if not fresh then return nil end
	SND.claimed = at
	return string.format("%s sound %.0fms ago, attempt %.0fms old",
		tostring(SND.lastFeintName), age * 1000, tokAge and (tokAge * 1000) or -1)
end

--=========================== THE COUNTER-PUNCH =============================
-- A feint has no hitbox. Dodging one is the fake paying off; the correct answer
-- is a punch thrown into the recovery the fake leaves behind - and the game's
-- own impact sound says whether it landed, which is the only outcome that
-- matters for a counter.
local function counterPunch(name, why)
	local at = now()
	SND.lastCounterAt = at
	counters.counter = counters.counter + 1
	press(cfg.counterKey, true, "counter")
	local hold = now() + (cfg.counterHoldMs / 1000)
	while now() < hold do end
	press(cfg.counterKey, false, "counter")
	log(string.format("COUNTER %s - %s, so %s goes out instead of a dodge (%dms hold). A fake has no hitbox; the real punch behind it still gets its own edge.",
		name, why, cfg.counterKey, cfg.counterHoldMs))
	task.spawn(function()
		local second = false
		local secondAt = at + (cfg.counterSecondMs / 1000)
		local until_ = at + (cfg.counterWatchMs / 1000)
		local landedAt = nil
		while now() < until_ do
			if landedAt == nil then
				local mine = SND.lastMyHitAt
				local counterCue = SND.lastCounterCueAt
				if mine ~= nil and mine >= at then landedAt = mine end
				if landedAt == nil and counterCue ~= nil and counterCue >= at then landedAt = counterCue end
			end
			if not second and now() >= secondAt then
				second = true
				-- only a second punch while nothing has landed: a feint cannot
				-- punish it, and a landed first punch does not need it
				if landedAt == nil and cfg.auto then
					counters.counter = counters.counter + 1
					press(cfg.counterKey, true, "counter2")
					local h2 = now() + (cfg.counterHoldMs / 1000)
					while now() < h2 do end
					press(cfg.counterKey, false, "counter2")
					log(string.format("COUNTER %s again at +%dms - the first punch produced no impact sound yet.", name, cfg.counterSecondMs))
				end
			end
			wait(0.01)
		end
		if landedAt ~= nil then
			SND.counterLanded = SND.counterLanded + 1
			counters.counterHit = counters.counterHit + 1
			log(string.format("COUNTER LANDED %s - the game's own impact sound arrived %.0fms after the punch.", name, (landedAt - at) * 1000))
		else
			SND.counterMissed = SND.counterMissed + 1
			counters.counterMiss = counters.counterMiss + 1
			log(string.format("COUNTER %s produced no impact sound inside %dms - no hit was confirmed, and a hit is the only reason to throw it.", name, cfg.counterWatchMs))
		end
	end)
end

-- TryAttack is CLEARED between punches, and a cleared slot is not an attack.
local function isAttackToken(tok)
	if tok == nil then return false end
	if type(tok) == "number" then return tok ~= 0 end
	if type(tok) ~= "string" then return true end
	local t = string.gsub(tok, "%s", "")
	if t == "" or t == "-" or t == "none" or t == "nil" or t == "0" then return false end
	return true
end

local function readToken(model)
	if model == nil then return nil end
	local raw = attr(model, "TryAttack")
	if not isAttackToken(raw) then return nil end
	local heavy = attr(model, "IsHeavy") == true
	local hand = attr(model, "AttackingHand")
	return tostring(raw), heavy, hand
end

--============================= THE LEDGER ==================================
-- The game's own dash bookkeeping. This is the instrument: LastDashTime moving
-- is the game saying "that press dashed", and the gap it records is the gate.
local LEDGER = { lastLocal = nil, pair = nil, pairAt = nil, dashAt = nil }

local function dashAttr(field)
	local m = myModel()
	if m == nil then return nil end
	local v = attr(m, field)
	if v == nil then return nil end
	return v
end

local function dashClock()
	local c = num(dashAttr("LocalCompensatedTime"))
	if c == nil then c = num(dashAttr("ClientsCompensatedTime")) end
	return c
end

local function lastDashTime()
	return num(dashAttr("LastDashTime"))
end

-- ms since the game logged a dash, or nil. The second value says where the
-- number came from: nil (the game's own pair), "local" (our stamp of the last
-- dash the game logged) or "frozen" (the pair stopped moving and the stamp
-- answered). A frozen pair reads as a real, small gap and skips good dodges:
-- 887ms at 297.99s and the same 887ms at 309.01s, with real dashes in between.
local function sinceLastDashMs()
	local last = lastDashTime()
	local c = dashClock()
	local d = nil
	if last ~= nil and c ~= nil then
		local diff = (c - last) * 1000
		if diff >= 0 and diff <= 60000 then d = diff end
	end
	local frozen = false
	if d ~= nil then
		if d ~= LEDGER.pair then
			LEDGER.pair, LEDGER.pairAt = d, now()
		elseif LEDGER.pairAt ~= nil
			and (now() - LEDGER.pairAt) >= (cfg.stalePairMs / 1000)
			and (LEDGER.lastLocal == nil or LEDGER.lastLocal <= LEDGER.pairAt) then
			frozen = true
			d = nil
		end
	end
	local from = nil
	if d == nil and LEDGER.lastLocal ~= nil then
		local diff = (now() - LEDGER.lastLocal) * 1000
		if diff >= 0 and diff <= 60000 then
			d = diff
			from = frozen and "frozen" or "local"
		end
	end
	return d, from
end

-- the game's clock, as this client sees it, so two of ITS timestamps subtract
local function serverNow()
	local c = num(dashAttr("LocalCompensatedTime"))
	if c == nil then c = num(dashAttr("ClientsCompensatedTime")) end
	if c == nil then
		local n = myName()
		local root = nil
		pcall(function() root = workspace.Live end)
		if root ~= nil and n ~= nil then
			local row = nil
			pcall(function() row = root:FindFirstChild(n) end)
			if row ~= nil then
				c = num(attr(row, "LocalCompensatedTime"))
				if c == nil then c = num(attr(row, "ClientsCompensatedTime")) end
			end
		end
	end
	return c
end

local function neededSide()
	local nd = dashAttr("NeededDirection")
	if nd == nil then return nil end
	local t = tostring(nd)
	if t == "Left" then return "left" end
	if t == "Right" then return "right" end
	if t == "Forward" then return "forward" end
	if t == "Backward" then return "back" end
	return nil
end

local function cachedDir()
	local d = dashAttr("CachedDashDirection")
	if d == nil then return nil end
	return tostring(d)
end

local function spamLevel()
	return num(dashAttr("DashSpamLevel"))
end

local function lastPerfect()
	return num(dashAttr("LastPerfectDodged"))
end

local function dashInvuln()
	return num(dashAttr("DashInvulnerable"))
end

local function ledgerLine()
	local since, from = sinceLastDashMs()
	local tbd = num(dashAttr("TimeBetweenDash"))
	local spam = spamLevel()
	local nd = neededSide()
	return string.format("sinceDash=%s tbd=%s spam=%s needed=%s",
		since and string.format("%.0fms%s", since, from and ("(" .. from .. ")") or "") or "?",
		tbd and string.format("%.3f", tbd) or "?",
		spam and string.format("%.3f", spam) or "?",
		tostring(nd or "-"))
end

--============================== DASH SPAM ==================================
-- The old file shipped maxSpamLevel=0.5, measured as "0.95 on a refused press".
-- This build reads 2.54 immediately after a dash that scored a PERFECT, so the
-- meter is not the 0..1 fraction that constant assumed and a 0.5 ceiling
-- refuses every window. It is not guessed at again: the values at presses and
-- at registrations are kept, and the gate stays off until a number earns it.
local SPAM = { press = {}, reg = {}, n = 0 }
SPAM.note = function(kind, v)
	if v == nil then return end
	local t = SPAM[kind]
	t[#t + 1] = v
	while #t > 40 do table.remove(t, 1) end
end
local function rangeOf(list)
	if #list == 0 then return "-" end
	local lo, hi = list[1], list[1]
	for _, v in ipairs(list) do
		if v < lo then lo = v end
		if v > hi then hi = v end
	end
	return string.format("%.2f..%.2f (n=%d)", lo, hi, #list)
end

--============================== THE STUN ===================================
-- ONE verdict, read by everything. The flag is a latch: it stays set after the
-- first stun of the match, so trusting it withheld two windows in three.
local function stunFlag()
	local v = valueOf(myName(), "Stunned")
	if v == true then return true end
	local a = attr(myModel(), "Stunned")
	if a == true then return true end
	local n = myName()
	local root = nil
	pcall(function() root = workspace.Live end)
	if root ~= nil and n ~= nil then
		local row = nil
		pcall(function() row = root:FindFirstChild(n) end)
		if row ~= nil and attr(row, "Stunned") == true then return true end
	end
	return false
end

local function stunUntil()
	local v = num(attr(myModel(), "StunnedUntil"))
	if v ~= nil then return v end
	local n = myName()
	local root = nil
	pcall(function() root = workspace.Live end)
	if root ~= nil and n ~= nil then
		local row = nil
		pcall(function() row = root:FindFirstChild(n) end)
		if row ~= nil then
			local a = num(attr(row, "StunnedUntil"))
			if a ~= nil then return a end
			local child = nil
			pcall(function() child = row:FindFirstChild("StunnedUntil") end)
			if child ~= nil then return num(safe(child, "Value")) end
		end
	end
	local m = myModel()
	if m ~= nil then
		local child = nil
		pcall(function() child = m:FindFirstChild("StunnedUntil") end)
		if child ~= nil then return num(safe(child, "Value")) end
	end
	return nil
end

local function stunVerdict()
	if cfg.stunGate == "off" then return false, "stun gate off", nil end
	local flag = stunFlag()
	if not flag then return false, "not stunned", nil end
	if cfg.stunGate == "flag" then return true, "stunned (the flag alone refuses)", nil end
	local until_ = stunUntil()
	local srv = serverNow()
	if until_ == nil or srv == nil then
		return true, "stunned (flag set, no deadline readable)", nil
	end
	local left = until_ - srv
	if left > 0 then
		return true, string.format("stunned, %.2fs left", left), left
	end
	return false, string.format("flag set but StunnedUntil passed %.2fs ago", -left), left
end

-- why a dodge would not be sent. Every reason here is the game refusing, known
-- before the press instead of measured after it.
-- aheadMs: the gate is asked aheadMs BEFORE the press (it is read before the
-- fuse spin now), so the gap it sees is that much smaller than the gap the game
-- will judge. Adding it back keeps the answer the one the press gets.
local function dashGate(aheadMs)
	if WORLD.opp == nil then return false, "no opponent" end
	local blocked, why = stunVerdict()
	if blocked then return false, "stun: " .. why end
	if dashing() then return false, "already dashing" end
	local st = stamina()
	if st ~= nil and st < cfg.minStamina then
		return false, string.format("stamina %.0f under %d", st, cfg.minStamina)
	end
	local sp = spamLevel()
	if sp ~= nil then
		SPAM.note("press", sp)
		if cfg.maxSpamLevel ~= nil and sp >= cfg.maxSpamLevel then
			return false, string.format("DashSpamLevel %.2f is at the %.2f limit", sp, cfg.maxSpamLevel)
		end
	end
	local since = sinceLastDashMs()
	if since ~= nil and (since + (aheadMs or 0)) < cfg.minDashGapMs then
		return false, string.format("only %.0fms since the game logged a dash (needs %d)", since, cfg.minDashGapMs)
	end
	return true, "clear"
end

-- the gate, with the one exception that is worth waiting for: a LIVE stun can
-- clear inside the punch's flight, and the press that lands right after it is
-- the only press that window can still spend. A stale flag never waits.
local function dashGateWaiting(aheadMs)
	local ok, why = dashGate(aheadMs)
	if ok then return true, "clear" end
	if cfg.stunWaitMs > 0 and string.find(why, "stun:", 1, true) then
		local blocked, _, left = stunVerdict()
		if blocked and left ~= nil and left > 0 then
			local until_ = now() + (cfg.stunWaitMs / 1000)
			while now() < until_ do
				local still = stunVerdict()
				if not still then
					counters.stunWait = counters.stunWait + 1
					return true, "the stun cleared mid-wait"
				end
				wait(0.01)
			end
			counters.stunHeld = counters.stunHeld + 1
			return false, "stun held for " .. cfg.stunWaitMs .. "ms and did not clear"
		end
	end
	return false, why
end

--============================== THE SIDE ===================================
local function sideFor(hand)
	local key = (hand == "LeftHand") and "LeftHand" or "RightHand"
	local side = (cfg.handMap and cfg.handMap[key]) or ((key == "LeftHand") and "left" or "right")
	if cfg.dirRule == "into" then
		return (side == "left") and "right" or "left"
	end
	return side
end

local function keyFor(side)
	if side == "left" then return cfg.leftKey end
	if side == "right" then return cfg.rightKey end
	if side == "forward" then return cfg.forwardKey end
	return cfg.backKey
end

local function wantDirFor(side)
	if side == "left" then return "Left" end
	if side == "right" then return "Right" end
	if side == "forward" then return "Forward" end
	return "Backward"
end

-- The fist in MY frame: the punching hand projected onto my right vector. This
-- is the thing the user is watching, and it is measurable here even though no
-- animation is. "count" only tallies the two groups - it does not steer.
local function frameAt(model)
	if model == nil or cfg.fistFrame == "off" then return nil end
	local mine = rootOf(myModel())
	local theirs = rootOf(model)
	if mine == nil or theirs == nil then return nil end
	local mpos = posOf(mine)
	local cf = safe(mine, "CFrame")
	local rv = cf and safe(cf, "RightVector") or nil
	if mpos == nil or rv == nil then return nil end
	local rx, ry, rz = num(safe(rv, "X")), num(safe(rv, "Y")), num(safe(rv, "Z"))
	if rx == nil or ry == nil or rz == nil then return nil end
	local hand = attr(model, "AttackingHand")
	local handName = (hand == "LeftHand" and "LeftHand") or (hand == "RightHand" and "RightHand") or nil
	if handName == nil then return nil end
	local part = nil
	pcall(function() part = model:FindFirstChild(handName) end)
	local p = posOf(part)
	if p == nil then return nil end
	local lat = (p.x - mpos.x) * rx + (p.y - mpos.y) * ry + (p.z - mpos.z) * rz
	local on = (lat > 0) and "right" or "left"
	return on, string.format("%s is %+.1f studs to my %s", handName, lat, on), lat
end

-- THE FIST AS A TIEBREAKER, never as a steer. It is consulted only when the
-- game publishes no NeededDirection for the attack; it is scored in its own
-- group and switches itself off if it loses (see maybeSwitchDir). It sits BELOW
-- frameAt() on purpose: a local declared after a function that calls it is not
-- an upvalue of it, and the reference would become a global.
local function fistSide()
	if cfg.dirFistFallback == "off" then return nil end
	local on = frameAt(WORLD.oppModel)
	if on ~= "left" and on ~= "right" then return nil end
	if cfg.dirRule == "into" then return on end
	return (on == "left") and "right" or "left"
end

-- IsFeinting is an epoch stamp written at the token. A stamp younger than
-- feintLiveS is a fake; the real punch behind one arrives 0.25..0.33s later,
-- which is what keeps this from cancelling the follow-up.
local FEINT = { last = nil, seen = 0, marked = 0, confirmed = 0, seenAt = nil, clockMiss = 0, cutAt = nil }

-- THE AGE IS MEASURED ON A CLOCK THAT RUNS. The stamp is the game's epoch value
-- and serverNow() is the game's clock - but that clock FREEZES in this build
-- (it is the same freeze the dash ledger needs stalePairMs for, and the same
-- pair that reported 887ms across sixty seconds of log). A frozen clock makes
-- srv - stamp NEGATIVE, i.e. "written in the future", i.e. never live - so a
-- feint could be sitting in the attribute and this never fired. The age that
-- cannot freeze is how long ago this script first saw the value, so a stamp
-- that is NEW is live by definition, and the game's own age is used only as a
-- second opinion when it agrees the stamp is young.
local function feintLive()
	local raw = attr(WORLD.oppModel, "IsFeinting")
	if raw == nil then return nil end
	local stamp = nil
	if raw == true then
		stamp = "true"
	else
		stamp = num(raw)
	end
	if stamp == nil then return nil end
	local fresh = false
	if FEINT.last ~= stamp then
		FEINT.last, FEINT.seenAt = stamp, now()
		FEINT.seen = FEINT.seen + 1
		fresh = true
	end
	local age = now() - (FEINT.seenAt or now())
	local srv = serverNow()
	if type(stamp) == "number" and srv ~= nil then
		local gameAge = srv - stamp
		if gameAge >= 0 and gameAge <= cfg.feintLiveS and not fresh then
			age = gameAge
		elseif gameAge < 0 then
			-- the game's clock is behind the stamp it wrote: count it, so the
			-- freeze is visible instead of silently eating every feint
			FEINT.clockMiss = FEINT.clockMiss + 1
		end
	end
	if age >= 0 and age <= cfg.feintLiveS then
		FEINT.marked = FEINT.marked + 1
		return string.format("IsFeinting written %.0fms ago", age * 1000)
	end
	return nil
end

--=========================== THE DIRECTION SCOREBOARD =======================
-- Every press is scored under the rule that chose its side, so the question
-- "who should decide the direction" is answered by outcomes instead of by a
-- manual A/B. The default stays with the game's NeededDirection because that is
-- what the measured buffers say (27 perfects against 1); the switch only fires
-- on a lead (>=8 judged, >=3 perfects, 3 perfects ahead) so a lucky pair of
-- dodges cannot flip it.
local DIR = {
	needed  = { n = 0, p = 0, h = 0 },
	mapping = { n = 0, p = 0, h = 0 },
	fist    = { n = 0, p = 0, h = 0 },
}

local function dirScoreLine()
	return string.format("dir score: needed %d/%d, mapping %d/%d, fist %d/%d (perfect/judged)",
		DIR.needed.p, DIR.needed.n, DIR.mapping.p, DIR.mapping.n, DIR.fist.p, DIR.fist.n)
end

local function maybeSwitchDir()
	if not cfg.dirAuto then return end
	local m, n, f = DIR.mapping, DIR.needed, DIR.fist
	if cfg.dirSource == "needed" and m.n >= 8 and m.p >= 3 and (m.p - n.p) >= 3 then
		cfg.dirSource = "auto"
		log(string.format("DIR SWITCH: the hand mapping is winning the scoreboard (%d PERFECT of %d against %d of %d for the game's side), so the mapping is the default now. _G.D.set(\"dirSource\", \"needed\") puts it back.", m.p, m.n, n.p, n.n))
	elseif cfg.dirSource == "auto" and n.n >= 8 and n.p >= 3 and (n.p - m.p) >= 3 then
		cfg.dirSource = "needed"
		log(string.format("DIR SWITCH: the game's own side is winning the scoreboard (%d PERFECT of %d against %d of %d for the mapping), so NeededDirection is the default again.", n.p, n.n, m.p, m.n))
	end
	if cfg.dirFistFallback == "auto" and f.n >= 6 and f.p == 0 and f.h >= 3 then
		cfg.dirFistFallback = "off"
		log(string.format("FIST SIDE OFF: it named the side %d times for no PERFECT and %d HITs, so the geometry no longer gets the call when the game publishes no side.", f.n, f.h))
	end
end

--=========================== MEASURED DASH LATENCY ==========================
-- dashUpMs used to be a constant (120) taken from the buffer. Every registration
-- now measures press -> the game logging the dash, and the median is what the
-- fuse arithmetic uses.
local LAT = { list = {}, n = 0, median = nil, first = nil }

local function noteLatency(ms)
	if ms == nil or ms < 15 or ms > 600 then return end
	LAT.list[#LAT.list + 1] = ms
	while #LAT.list > 9 do table.remove(LAT.list, 1) end
	LAT.n = LAT.n + 1
	if #LAT.list < 3 then return end
	local m = math.floor(medianOf(LAT.list) + 0.5)
	if LAT.median == nil or math.abs(m - LAT.median) >= 8 then
		local was = LAT.median
		LAT.median = m
		log(string.format("DASH LATENCY %s: the game logs the dash %.0fms after the press (median of %d) - the fuse arithmetic uses this from now on. Was: %s.", LAT.first == nil and "measured" or "re-measured", m, #LAT.list, was and (was .. "ms") or "the " .. cfg.dashUpMs .. "ms default"))
		LAT.first = m
	end
end

local function dashUp()
	return LAT.median or cfg.dashUpMs
end

--=========================== MEASUREMENT ===================================
-- landing offsets, per opponent, light vs heavy. This is what makes the heavy
-- fuse conditional and the per-opponent fuse measurable: it is fed only by
-- punches that actually landed on us.
local LAND = { data = {} }
local function landOf(name)
	if name == nil then name = "?" end
	if LAND.data[name] == nil then
		LAND.data[name] = { light = {}, heavy = {}, late = {}, hl = {} }
	end
	return LAND.data[name]
end
function LAND.reset(name)
	return landOf(name)
end
local function pushSample(list, v, cap)
	list[#list + 1] = v
	while #list > (cap or 12) do table.remove(list, 1) end
end

-- the fuse for this opponent: fireMs until their own winning landings have
-- been measured, then median - dashUpMs - coverMarginMs. One-directional, and
-- never under the feint guard.
local function fuseFor(name, heavy)
	local base = cfg.fireMs
	local measuredHeavy = false
	if cfg.fusePerOpp then
		local row = landOf(name)
		if heavy and row.fuseHeavy ~= nil then
			base, measuredHeavy = row.fuseHeavy, true
		elseif row.fuse ~= nil then
			base = row.fuse
		end
	end
	if heavy and cfg.heavyExtraMs > 0 and not measuredHeavy then
		local row = landOf(name)
		local l = medianOf(row.light)
		local h = medianOf(row.heavy)
		if l ~= nil and h ~= nil and (h - l) >= cfg.heavyLateGapMs then
			base = base + cfg.heavyExtraMs
		end
	end
	if cfg.antiFeint and cfg.feintGuardMs > 0 and base < cfg.feintGuardMs then
		base = cfg.feintGuardMs
	end
	return math.floor(clamp(base, cfg.minFireMs, cfg.maxFireMs) + 0.5)
end

-- the same arithmetic on the startup clock. The default is the delay the short
-- script in the wild uses (250ms) and it is replaced by this opponent's own
-- measured landings, measured from the edge, as soon as there are enough of
-- them - so the number that script hard-codes becomes the number this file
-- learns.
local function hlFuseFor(name, heavy)
	local row = landOf(name)
	local learned = (cfg.fusePerOpp and row.hlFire ~= nil)
	local base = learned and row.hlFire or cfg.startupMs
	if heavy and cfg.heavyExtraMs > 0 and not learned then
		base = base + cfg.heavyExtraMs
	end
	if cfg.antiFeint and cfg.feintGuardMs > 0 and base < cfg.feintGuardMs then
		base = cfg.feintGuardMs
	end
	return math.floor(clamp(base, cfg.startupMinMs, cfg.startupMaxMs) + 0.5)
end

-- THE SMIDGE, and what it costs. A feint is cancelled by the stamp long before
-- the press, but only if the stamp arrives in time - so against an opponent that
-- HAS feinted this session the press waits a little longer before committing.
-- It is not free: the dash has to be up before their punch lands, so the wait is
-- cut back to whatever room is left once their own landing has been measured
-- (landing - the measured dash latency - the fuse). The log says when that
-- happens and by how much, instead of quietly doing nothing.
local function feintPatience(name, fuse)
	local want = cfg.feintPatienceMs
	if want == nil or want <= 0 then return 0 end
	-- nobody has feinted at us yet: there is nothing to wait for
	if FEINT.seen == 0 then return 0 end
	local x = medianOf(landOf(name).light)
	if x == nil then return want end
	local room = math.floor(x - dashUp() - fuse)
	if room < 0 then room = 0 end
	if room < want then
		if FEINT.cutAt == nil or (now() - FEINT.cutAt) > 10 then
			FEINT.cutAt = now()
			log(string.format("FEINT PATIENCE cut to %dms: they land at %.0fms, the dash takes %.0fms and the fuse is %dms, so +%d would press too late. _G.D.set(\"fireMs\", %d) buys room for it.",
				room, x, dashUp(), fuse, want, math.max(cfg.minFireMs, fuse - want)))
		end
		return room
	end
	return want
end

-- the press offset this exchange will aim at: the fuse, plus the feint wait
local function pressFuse(name, heavy)
	local base = fuseFor(name, heavy)
	local wait = feintPatience(name, base)
	if wait > 0 then counters.feintWait = counters.feintWait + 1 end
	FEINT.lastWait = wait
	return math.floor(clamp(base + wait, cfg.minFireMs, cfg.maxFireMs) + 0.5)
end

-- THE FUSE IS A WINDOW. A dash has to be up before the punch lands and its
-- i-frames still running when it does, so:
--     the dash is up in time      press + latency        < landing - margin
--     the i-frames are not spent  press + latency + iframe > landing
-- The valid press window is therefore
--     [ landing - latency - iframe , landing - latency - margin ]
-- and the fuse aims at its middle. The old rule was the RIGHT-HAND EDGE of that
-- window (press as late as possible), which is exactly the guess that turns
-- into an early press when the latency estimate is off - and an early press has
-- no answer for a double token. Aiming at the middle costs a little margin on
-- both sides and needs neither of them to be exact.
local function windowCentre(x)
	local up = dashUp()
	local lo = x - up - cfg.iframeMs
	local hi = x - up - cfg.coverMarginMs
	return (lo + hi) / 2, lo, hi
end

local function learnWindow(name)
	if not cfg.fusePerOpp then return end
	local row = landOf(name)

	local function apply(list, key, label, minN, floorMs, capMs)
		if #list < minN then return end
		local x = medianOf(list)
		if x == nil then return end
		local centre, lo, hi = windowCentre(x)
		local want = math.floor(clamp(centre,
			floorMs or math.max(cfg.minFireMs, cfg.feintGuardMs), capMs or cfg.fireMs) + 0.5)
		local old = row[key] or cfg.fireMs
		if row[key] == want then return end
		row[key] = want
		log(string.format("FUSE %s (%s): their punches land at %.0fms of the token (median of %d), the dash comes up in %.0fms and the i-frames last %dms - so the press window is [%.0f, %.0f] and the %s fuse goes from +%d to +%d.",
			name, label, x, #list, dashUp(), cfg.iframeMs, lo, hi, label, old, want))
	end

	apply(row.light, "fuse", "light", cfg.fusePerOppMin)
	apply(row.heavy, "fuseHeavy", "heavy", math.max(2, cfg.fusePerOppMin - 1))
	apply(row.hl, "hlFire", "startup", cfg.fusePerOppMin, cfg.startupMinMs, cfg.startupMaxMs)
end

--================================ EXCHANGE =================================
-- One punch, one linear pass. There is no second window, no cancellation tree
-- and no thread: a token that arrives mid-fuse re-arms THIS window, and a
-- token that arrives after the press is the loop's job on the next tick.
local function spinTo(target, onTick)
	while true do
		local left = target - now()
		if left <= 0 then return end
		if onTick ~= nil then onTick() end
		if left > (cfg.spinMs / 1000) then
			wait(math.min(0.01, left - cfg.spinMs / 1000))
		else
			-- THE GUARD WAS THE BUG. Four thousand iterations of now() is one to
			-- four MILLISECONDS, so this loop always broke out long before the
			-- target: the press fired spinMs early every single time and the
			-- "measured" lateness was the work that ran after it. Measured on the
			-- live build: spinTo(170ms) returned +23ms EARLY with spinMs=25 and
			-- +58ms early with spinMs=60, i.e. it always gave up. The escape hatch
			-- is now time-based, so only a stalled clock can trip it, and onTick is
			-- called once here instead of every eighth iteration - each call is an
			-- attribute read worth 2-6ms, which is more than the whole spin.
			if onTick ~= nil then onTick() end
			local guardUntil = target + 0.5
			while now() < target do
				if now() > guardUntil then break end
			end
			return
		end
	end
end

-- did the game log a dash? LastDashTime first, then the two backups it also
-- keeps, because a perfect does not always pulse Dashing.
local function registeredSince(pre)
	local last = lastDashTime()
	if last ~= nil and pre.last ~= nil and last ~= pre.last then
		return true, "the game logged a dash"
	end
	local inv = dashInvuln()
	if inv ~= nil and pre.inv ~= nil and inv ~= pre.inv then
		return true, "DashInvulnerable moved"
	end
	local st = stamina()
	if st ~= nil and pre.stam ~= nil and (pre.stam - st) >= 3 then
		return true, string.format("stamina %.0f -> %.0f", pre.stam, st)
	end
	local d = cachedDir()
	if d ~= nil and pre.dir ~= nil and d ~= pre.dir then
		return true, "CachedDashDirection changed"
	end
	return false, nil
end

local function score(side, pre, pressedAt)
	-- settle the direction: the first read after a dash can still be the
	-- PREVIOUS dash's value, so the last read in the settle window is judged
	local want = wantDirFor(side)
	local settleUntil = pressedAt + (cfg.dirSettleMs / 1000)
	local dir = nil
	while now() < settleUntil do
		local d = cachedDir()
		if d ~= nil then dir = d end
		wait(0.01)
	end
	if dir == nil then dir = cachedDir() end
	if dir == want then
		counters.dirOk = counters.dirOk + 1
	elseif dir == nil then
		counters.dirUnknown = counters.dirUnknown + 1
	else
		counters.dirBad = counters.dirBad + 1
	end
	return dir, want
end

local function exchange(tok, heavy, hand, reason, startAt)
	local opp = WORLD.opp
	local name = opp and opp.name or "?"
	-- THE CLOCK. The token path starts at the token. The startup path starts at
	-- the highlight edge, which the game publishes for the attack itself - the
	-- edge is the cheapest read here, so the window starts before the twelve
	-- attribute reads the token path needs instead of after them. When the token
	-- lands late the edge keeps the clock and the token only says hand / heavy /
	-- side (see during()).
	local clockStartup = (reason == "startup" and startAt ~= nil)
	local tokenAt = startAt or now()
	local fuse = clockStartup and hlFuseFor(name, heavy) or pressFuse(name, heavy)
	local side = sideFor(hand)
	local nd = neededSide()
	local basis = "mapping"
	if cfg.dirSource == "needed" and (nd == "left" or nd == "right") then
		if nd ~= side then
			counters.neededMoved = counters.neededMoved + 1
		end
		counters.neededUsed = counters.neededUsed + 1
		side, basis = nd, "needed"
	elseif cfg.dirSource == "needed" and nd == nil then
		-- nothing from the game for THIS attack: the fist geometry gets the
		-- call, and it is scored so it can lose it again
		local fs = fistSide()
		if fs ~= nil and fs ~= side then
			side, basis = fs, "fist"
		end
	end
	local basisNote = ""
	if basis == "needed" then
		basisNote = "  [the game named this side]"
	elseif basis == "fist" then
		basisNote = "  [no side from the game - the fist geometry named it]"
	end
	local key = keyFor(side)
	local dirSide = side

	local pre = {
		health = health(), meter = meter(), last = lastDashTime(),
		stam = stamina(), dir = cachedDir(), inv = dashInvuln(),
		perfect = lastPerfect(),
	}
	local frameOn, frameShow = frameAt(opp and opp.model)

	counters.exchanges = counters.exchanges + 1
	if cfg.verbose then
		log(string.format("ATTEMPT %s hand=%s heavy=%s dist=%s -> %s in %dms%s%s%s%s  keys-you: %s",
			name, tostring(hand), heavy and "yes" or "no",
			opp and opp.dist and string.format("%.1f", opp.dist) or "?",
			side, fuse, basisNote,
			(not clockStartup and FEINT.lastWait ~= nil and FEINT.lastWait > 0)
				and string.format("  [+%dms feint patience]", FEINT.lastWait) or "",
			(reason and reason ~= "token") and ("  [" .. reason .. "]") or "",
			clockStartup and "  [clock = startup highlight]" or "",
			keySnap()))
	end

	-- the direction key goes down EARLY, so the tap itself is the only thing
	-- that has to happen on time
	press(key, true, "dir")
	local cancelled = nil
	local pressedAt = nil
	local pressOffset = nil
	-- set when during() re-arms the window on a newer token: the gate and the
	-- ledger were read for the OLD press moment and have to be read again
	local regate = false

	local function during()
		if cancelled ~= nil then return end
		-- 1. the feint, from the game's own stamp, which is written ~150ms
		--    before the press would be
		if cfg.feintStamp and (cfg.antiFeint or cfg.counter) then
			local f = nil
			if cfg.counter and cfg.soundCues then f = soundFeint() end
			-- the same fake arriving late: the sound already answered it
			if f == nil and cfg.antiFeint
				and (ANSWERED.at == nil or (now() - ANSWERED.at) >= (cfg.feintOnceMs / 1000)) then
				f = feintLive()
			end
			if f ~= nil then
				cancelled = "feint"
				counters.feint = counters.feint + 1
				if clockStartup then counters.feintHl = counters.feintHl + 1 end
				-- THE THING THE SHORT SCRIPT CANNOT DO. It presses on every
				-- highlight, so every fake it is shown costs it a dodge. The
				-- stamp is checked here, at the press moment, and on the startup
				-- clock the edge bought this check the whole delay to see it.
				log(string.format("FEINT %s at +%.0fms of the %s - %s. DODGE CANCELLED, no stamina spent; the follow-up gets its own window and the edge is watched again.",
					name, (now() - tokenAt) * 1000, clockStartup and "startup highlight" or "token", f))
				if cfg.counter then
					ANSWERED.at = now()
					counterPunch(name, f)
				end
				-- swallow the token this window belonged to, or the loop arms the
				-- SAME attack again on the token path and cancels it twice
				local t3 = readToken(WORLD.oppModel)
				if t3 ~= nil then WORLD.tok = t3 end
				return
			end
		end
		-- 2. the game may name the other side at any moment in the pre-hold
		if cfg.neededPoll and cfg.dirSource == "needed" then
			local live = neededSide()
			if (live == "left" or live == "right") and live ~= dirSide then
				local was = dirSide
				press(key, false, "dir")
				dirSide, side = live, live
				key = keyFor(live)
				press(key, true, "dir")
				counters.neededMoved = counters.neededMoved + 1
				log(string.format("NEEDED %s: %s -> %s at +%.0fms of the token, the key follows the game.",
					name, was, live, (now() - tokenAt) * 1000))
			end
		end
		-- 3. a NEW token while the keys are down is the live punch (this is the
		--    feint defence, and it is also a double token): restart on it
		local t2, h2, hd2 = readToken(WORLD.oppModel)
		if t2 ~= nil and t2 ~= tok then
			local at = now()
			local adopt = clockStartup and (((at - tokenAt) * 1000) <= cfg.startupAdoptMs)
			tok, heavy, hand = t2, h2, hd2
			WORLD.tok = t2
			local want = sideFor(hand)
			local live = neededSide()
			if cfg.dirSource == "needed" and (live == "left" or live == "right") then want = live end
			if want ~= dirSide then
				press(key, false, "dir")
				dirSide, side = want, want
				key = keyFor(want)
				press(key, true, "dir")
			end
			if adopt then
				-- the SAME attack, published after the highlight: the edge keeps
				-- the clock and the token only fills in what it names
				noteLead((at - tokenAt) * 1000)
				log(string.format("TOKEN %s +%.0fms after the startup highlight - the same attack arriving late, so the clock stays on the edge (hand=%s, heavy=%s, side=%s).",
					name, (at - tokenAt) * 1000, tostring(hand), heavy and "yes" or "no", side))
			else
				clockStartup = false
				tokenAt = at
				fuse = pressFuse(name, heavy)
				regate = true
				counters.rearm = counters.rearm + 1
				log(string.format("RE-ARM %s: a new token arrived while the keys were down, so the fuse restarts on it (+%dms, hand=%s).",
					name, fuse, tostring(hand)))
			end
		end
	end

	-- THE GATE AND THE LEDGER ARE READ BEFORE THE SPIN, NOT AFTER IT. Every call
	-- here is one or more attribute reads and this executor charges 2-6ms for
	-- one; nine of them sat between the last wait and the press, which is the
	-- measured 50ms that put every press at token+219ms on a 170ms fuse (the
	-- log's own press offset was 214ms median over 30 samples, and the 20 HIT
	-- lines are that lateness: their punches landed at +297ms of the token).
	-- What happens after the spin now is the press and nothing else.
	-- The gate is asked with the fuse as its "ahead" figure, because it is being
	-- asked that much earlier than the press it is deciding.
	local gateOk, gateWhy = dashGateWaiting(fuse)
	local preBlocked = stunVerdict()
	local preFlag = stunFlag()
	local preSince = sinceLastDashMs()
	local preStam = stamina()
	local preSpam = spamLevel()
	local preLedger = ledgerLine()
	-- how far ahead of the press those reads were taken, so the DODGE line still
	-- prints the gap the game will judge instead of a number fuse ms too small
	local gapAhead = fuse

	spinTo(tokenAt + (fuse / 1000), during)

	-- a re-armed window moved the press, so those reads describe an instant that
	-- no longer exists; they are redone, which is costly and rare on purpose
	if regate then
		gateOk, gateWhy = dashGateWaiting(fuse)
		preBlocked = stunVerdict()
		preFlag = stunFlag()
		preSince = sinceLastDashMs()
		preStam = stamina()
		preSpam = spamLevel()
		preLedger = ledgerLine()
		gapAhead = 0
	end

	-- the press, or the reason there is none
	if cancelled == nil and not gateOk then
		local why = gateWhy
		cancelled = why
		if string.find(why, "stun", 1, true) then
			warn(string.format("SKIP %s: %s. The window is kept - nothing was spent.", name, why))
		else
			counters.skipped = counters.skipped + 1
			log(string.format("SKIP %s: %s.", name, why))
		end
	end

	if cancelled == nil then
		-- the gate said yes; the press is the tap and nothing else
		if not preBlocked and preFlag then
			counters.stalePress = counters.stalePress + 1
			counters.staleStun = counters.staleStun + 1
		end
		-- the tap IS the press moment. Taking the stamp after the hold put every
		-- reported offset 40ms late and anchored the landing watch to it.
		press(cfg.dodgeKey, true, "dash")
		pressedAt = now()
		local hold = pressedAt + (cfg.pressHoldMs / 1000)
		while now() < hold do end
		press(cfg.dodgeKey, false, "dash")
		pressOffset = (pressedAt - tokenAt) * 1000
		local releaseOffset = (now() - tokenAt) * 1000
		counters.presses = counters.presses + 1
		if clockStartup then
			counters.hlPress = counters.hlPress + 1
			pushSample(HL.fire, pressOffset, 12)
		end
		pushSample(counters.poff, pressOffset, 30)
		log(string.format("DODGE %s %s over=%+.0fms rel=%+.0fms gap=%s stam=%s spam=%s  %s",
			name, side, pressOffset, releaseOffset,
			preSince and string.format("%.0fms", preSince + gapAhead) or "?",
			preStam and string.format("%.0f", preStam) or "?",
			preSpam and string.format("%.2f", preSpam) or "?",
			preLedger))
	end

	-- keep the direction down past the press, then let go of everything
	local releaseAt = (pressedAt and (pressedAt + cfg.dirReleaseMs / 1000)) or (now() + cfg.dirReleaseMs / 1000)
	while now() < releaseAt do wait(0.005) end
	press(key, false, "dir")

	if pressedAt == nil then
		return
	end

	-- ONE post-press watch. Registration, the settled direction, the landing and
	-- the meter are sampled in the SAME loop. The earlier shape waited out the
	-- whole confirmMs registration window before it looked at health, so a punch
	-- that landed 154ms after the press was timestamped +620ms and every hit in
	-- the log read as a LATER punch. Sampling them together costs nothing and
	-- removes that blind spot.
	local reg, how = false, nil
	local retried = false
	local regDeadline = pressedAt + (cfg.confirmMs / 1000)
	local settleUntil = pressedAt + (cfg.dirSettleMs / 1000)
	local watchUntil = pressedAt + (cfg.exchangeMs / 1000)
	local dir, hitAt, meterAt = nil, nil, nil
	local pendingTok = nil

	while now() < watchUntil do
		-- a NEW token while this window is still scoring is the next punch, and
		-- in a real fight it arrives inside this window: a fast opponent throws
		-- every ~300ms while the landing watch is 1200ms long. Waiting it out
		-- would arm the next dodge a second late, so the window ends here and
		-- the loop arms the new token on its next tick.
		local t2 = readToken(WORLD.oppModel)
		if t2 ~= nil and t2 ~= tok then
			pendingTok = t2
			break
		end
		if not reg then
			local r, whyReg = registeredSince(pre)
			if r then
				reg, how = true, whyReg
				LEDGER.lastLocal = now()
				noteLatency((now() - pressedAt) * 1000)
				SPAM.note("reg", spamLevel())
				log(string.format("REGISTERED %s at +%.0fms after the press - %s.", name, (now() - pressedAt) * 1000, how))
			elseif now() >= regDeadline and not retried then
				retried = true
				warn(string.format("NOT REGISTERED %s - no dash, no i-frames. %s", name, ledgerLine()))
				-- one more press is worth it only while nothing has landed, no
				-- dash is up and the game's own gate is open: a refused press
				-- costs no stamina, and a retry has scored a PERFECT before.
				local h2 = health()
				local untouched = (h2 == nil or pre.health == nil or h2 >= (pre.health - 0.5))
				local gateOK, whyG = dashGate()
				if cfg.retryMax > 0 and untouched and gateOK then
					counters.retry = counters.retry + 1
					press(key, true, "dir")
					local preAt = now() + (cfg.preholdMs / 1000)
					while now() < preAt do wait(0.005) end
					tapFor(cfg.dodgeKey, cfg.pressHoldMs)
					press(key, false, "dir")
					pressedAt = now()
					pressOffset = (pressedAt - tokenAt) * 1000
					regDeadline = pressedAt + (cfg.confirmMs / 1000)
					settleUntil = pressedAt + (cfg.dirSettleMs / 1000)
					watchUntil = pressedAt + (cfg.exchangeMs / 1000)
					dir = nil
					log(string.format("RETRY %s at +%.0fms of the token - the first press produced no dash. %s",
						name, pressOffset, ledgerLine()))
				elseif not gateOK then
					log(string.format("RETRY withheld %s: %s", name, whyG))
				end
			end
		end
		local d = cachedDir()
		if d ~= nil and now() <= settleUntil then dir = d end
		local h = health()
		if hitAt == nil and h ~= nil and pre.health ~= nil and h < (pre.health - 0.5) then
			hitAt = now()
		end
		local m = meter()
		if meterAt == nil and m ~= nil and pre.meter ~= nil and m > (pre.meter + 0.5) then
			meterAt = now()
		end
		if meterAt == nil and lastPerfect() ~= nil and pre.perfect ~= nil and lastPerfect() ~= pre.perfect then
			meterAt = now()
		end
		wait(0.005)
	end

	if reg then
		counters.registered = counters.registered + 1
	else
		counters.unregistered = counters.unregistered + 1
		if not retried then
			warn(string.format("NOT REGISTERED %s - no dash, no i-frames. %s", name, ledgerLine()))
		end
	end
	if pendingTok ~= nil then
		log(string.format("RE-TARGET %s: a new token arrived while this window was scoring, so the window ends here (+%.0fms after the press) and the next punch gets its own.",
			name, (now() - pressedAt) * 1000))
	end
	if dir == nil then dir = cachedDir() end
	local want = wantDirFor(side)
	if dir == want then
		counters.dirOk = counters.dirOk + 1
	elseif dir == nil then
		counters.dirUnknown = counters.dirUnknown + 1
	else
		counters.dirBad = counters.dirBad + 1
	end
	local dirTxt = string.format("DIR %s: the game stored %s, wanted %s%s",
		name, tostring(dir or "?"), want,
		(dir == want) and " - CORRECT" or (dir == nil and " - unreadable" or " - WANTED"))

	local early = (hitAt ~= nil) and ((hitAt - pressedAt) * 1000) or nil
	local verdict
	if hitAt ~= nil and early ~= nil and early <= (cfg.iframeMs + 200) then
		verdict = "HIT"
		counters.hit = counters.hit + 1
		-- a punch that landed while OUR dash was up is a timing sample; a punch
		-- that landed with no dash at all is a landing to learn the fuse from
		local row = landOf(name)
		local offset = (hitAt - tokenAt) * 1000
		-- the landing belongs to the clock it was measured on: the startup row
		-- teaches the startup delay, the token rows teach the token fuse, and
		-- neither is allowed to poison the other
		local bucket
		if clockStartup then bucket = row.hl
		elseif heavy then bucket = row.heavy
		else bucket = row.light end
		pushSample(bucket, offset)
		if not reg then
			log(string.format("HIT %s +%.0fms after the press, NO DASH REGISTERED so those i-frames were never up - their punch landed at +%.0fms of its token. The press was too late (or refused). %s",
				name, early, offset, dirTxt))
		else
			local closed = (early > (dashUp() + cfg.iframeMs))
			log(string.format("HIT %s +%.0fms after the press with the dash up - the dash comes up at +%.0fms and the i-frames last %dms, so the window was %s. %s",
				name, early, dashUp(), cfg.iframeMs,
				closed and "already CLOSED when it landed (the press was too EARLY)" or "still open when it landed (the side was wrong, not the timing)",
				dirTxt))
		end
		-- both halves feed the window arithmetic: one landing says where the
		-- punch was, whichever way the press was wrong
		learnWindow(name)
	elseif hitAt ~= nil then
		verdict = "LATE"
		counters.late = counters.late + 1
		log(string.format("LATE HIT %s +%.0fms after the press - past the i-frame window, so this is a LATER punch and it is never fed to the fuse. %s",
			name, early or 0, dirTxt))
	elseif meterAt ~= nil and ((meterAt - pressedAt) * 1000) <= cfg.perfectWindowMs then
		verdict = "PERFECT"
		counters.perfect = counters.perfect + 1
		log(string.format("PERFECT %s - no damage and the meter moved %.0fms after the press. %s", name,
			(meterAt - pressedAt) * 1000, dirTxt))
	else
		verdict = "CLEAN"
		counters.clean = counters.clean + 1
		log(string.format("CLEAN %s - no damage and no meter jump. %s", name, dirTxt))
	end

	-- which rule chose the side, scored by the outcome it produced
	local dbucket = DIR[basis]
	if dbucket ~= nil and verdict ~= nil then
		dbucket.n = dbucket.n + 1
		if verdict == "PERFECT" then dbucket.p = dbucket.p + 1 end
		if verdict == "HIT" then dbucket.h = dbucket.h + 1 end
		maybeSwitchDir()
	end

	-- the geometry bucket, scored by outcome so the log settles into/away
	if frameOn ~= nil and verdict ~= nil then
		local bucket = (frameOn == side) and counters.frameInto or counters.frameAway
		bucket.n = bucket.n + 1
		if verdict == "PERFECT" then bucket.p = bucket.p + 1 end
		if verdict == "HIT" then bucket.h = bucket.h + 1 end
	end

	-- the cover dash: a heavy whose first press produced nothing and whose
	-- landing has not happened yet gets a second dash timed for the ~900ms
	-- windup. One per window, and only while nothing has landed.
	if heavy and cfg.heavyCover and not reg and hitAt == nil and pendingTok == nil then
		local coverAt = tokenAt + (cfg.heavyCoverAtMs / 1000)
		if coverAt > now() then
			while now() < coverAt do wait(0.01) end
			local ok2, why2 = dashGate()
			local h3 = health()
			local stillClean = (h3 == nil or pre.health == nil or h3 >= (pre.health - 0.5))
			if ok2 and stillClean then
				counters.cover = counters.cover + 1
				press(key, true, "dir")
				local preAt = now() + (cfg.heavyCoverPreholdMs / 1000)
				while now() < preAt do wait(0.005) end
				tapFor(cfg.dodgeKey, cfg.pressHoldMs)
				press(key, false, "dir")
				log(string.format("COVER DASH %s at +%.0fms of the token - a ~900ms windup outlives the first dash. %s",
					name, (now() - tokenAt) * 1000, ledgerLine()))
			elseif not ok2 then
				log(string.format("COVER DASH skipped %s: %s", name, why2))
			end
		end
	end

	if cfg.verbose and frameShow ~= nil then
		log("  fist frame: " .. frameShow)
	end
end

--================================= LOOP ====================================
local running = true
local lastStatus = now()

--============================ AM I IN THE RINK =============================
-- The game does not stop publishing punch tokens when this character leaves the
-- ring: it keeps the opponent locked on and keeps the punches coming, so a
-- spectator's client sees a full token stream and the old gate (which only
-- asked "is there an opponent?") said yes. Four dashes at nobody while the
-- camera is watching someone else's fight is the single most obvious thing
-- this file can do, so the press now waits for the canvas.
--
-- The geometry comes from the game, not from a guess: every model in
-- workspace.Rings carries an "Actual Ring" model whose canvas mesh gives the
-- floor's position and size - ring 12 measured 34.8 x 34.5 studs centred at
-- 41.0, -3.8, 69.3 while the character stood at 4.0, 0.3, 20.6. The gate is
-- therefore "my root is over a canvas, with a margin", and it is read the same
-- way in every ring on the map.
local RINK = { parts = nil, at = nil, last = nil }

local function rinkParts()
	if RINK.parts ~= nil and RINK.at ~= nil and (now() - RINK.at) < (cfg.rinkCacheMs / 1000) then
		return RINK.parts
	end
	local parts = {}
	local rings = nil
	pcall(function() rings = workspace.Rings end)
	if rings == nil then pcall(function() rings = workspace:FindFirstChild("Rings") end) end
	if rings ~= nil then
		local ok, list = pcall(function() return rings:GetChildren() end)
		if ok and list then
			for _, ring in ipairs(list) do
				local ar = nil
				pcall(function() ar = ring:FindFirstChild("Actual Ring") end)
				if ar == nil then pcall(function() ar = ring:FindFirstChild("ActualRing") end) end
				if ar ~= nil then
					local ok2, kids = pcall(function() return ar:GetDescendants() end)
					if ok2 and kids then
						for _, kid in ipairs(kids) do
							local nm = tostring(safe(kid, "Name") or "")
							-- the canvas is the floor; the ropes and pads are not the ring
							if string.find(nm, "Canvas", 1, true) ~= nil then
								local p = posOf(kid)
								local s = nil
								pcall(function() s = kid.Size end)
								local sx = s and num(safe(s, "X")) or nil
								local sz = s and num(safe(s, "Z")) or nil
								if p ~= nil and sx ~= nil and sz ~= nil and sx > 4 and sz > 4 then
									parts[#parts + 1] = { x = p.x, y = p.y, z = p.z, hx = sx / 2, hz = sz / 2 }
								end
							end
						end
					end
				end
			end
		end
	end
	RINK.parts, RINK.at = parts, now()
	if #parts == 0 then
		warn("RINK: no canvas could be read under workspace.Rings (" .. tostring(rings ~= nil and #(rings:GetChildren()) or 0) .. " ring(s) seen). The rink gate is therefore NOT holding anything back - _G.D.set(\"requireRink\", true) will not help until this reads.")
	end
	return parts
end

-- true / false, or nil when the question cannot be answered. nil is deliberately
-- permissive: a build whose rings do not read must not become unable to dodge.
local function inRink()
	local parts = rinkParts()
	if parts == nil or #parts == 0 then return nil end
	local p = posOf(rootOf(myModel()))
	if p == nil then return nil end
	for _, c in ipairs(parts) do
		if math.abs(p.x - c.x) <= (c.hx + cfg.rinkMargin)
			and math.abs(p.z - c.z) <= (c.hz + cfg.rinkMargin)
			and math.abs(p.y - c.y) <= cfg.rinkYSlack then
			return true
		end
	end
	return false
end

--=========================== THE STARTUP ENGINE ============================
-- The measured answer to "why does the twenty-line script dodge better":
--   * it presses on the EDGE, not on a computed moment,
--   * it presses AGAIN while the highlight is still up, so one refused press
--     does not lose the attack (a refusal costs 1 stamina of 100: measured
--     81.19 -> 80.19),
--   * it never withholds a press.
-- Measured in one live fight, presses 250-265ms after the edge: 5 of 7 landed,
-- bare Space and Space-with-a-direction-key alike (3/5 and 2/3), so the
-- direction key was never the problem. This file's gate was: 8 windows withheld,
-- 6 of 25 presses registered. What this engine adds is the one thing the short
-- script cannot do - the game's own IsFeinting stamp is read before EVERY press,
-- so a fake is skipped and the punch behind it still gets pressed.
local SLOP = { lastPress = nil, presses = 0, reg = 0, refused = 0, feints = 0, offs = {},
	counterAt = nil }

local function startupPress(opp, name, offsetMs)
	local preLast, preStam = lastDashTime(), stamina()
	local preH, preM, preP = health(), meter(), lastPerfect()
	local pressedAt = now()
	press(cfg.dodgeKey, true, "dash")
	local hold = now() + (cfg.startupHoldMs / 1000)
	while now() < hold do end
	press(cfg.dodgeKey, false, "dash")
	SLOP.presses = SLOP.presses + 1
	counters.presses = counters.presses + 1
	pushSample(SLOP.offs, offsetMs, 20)
	log(string.format("DODGE %s bare %s at +%.0fms of the startup highlight (%dms hold, no direction key, nothing withheld) stam=%s",
		name, tostring(cfg.dodgeKey), offsetMs, cfg.startupHoldMs, preStam and string.format("%.0f", preStam) or "?"))
	-- the game's answer, off the critical path. Stamina is the signal that does
	-- not freeze: LastDashTime sat stuck for 14-23s mid-fight in v3's log.
	task.spawn(function()
		local deadline = now() + 0.45
		while now() < deadline do wait(0.02) end
		local postLast, postStam = lastDashTime(), stamina()
		local reg = (preLast ~= nil and postLast ~= nil and postLast ~= preLast)
			or (preStam ~= nil and postStam ~= nil and (preStam - postStam) >= 3)
		if reg then
			SLOP.reg = SLOP.reg + 1
			counters.registered = counters.registered + 1
			if preStam ~= nil and postStam ~= nil then
				log(string.format("REGISTERED %s - stamina %.0f -> %.0f.", name, preStam, postStam))
			else
				log(string.format("REGISTERED %s.", name))
			end
		else
			SLOP.refused = SLOP.refused + 1
			counters.unregistered = counters.unregistered + 1
			-- stamina REGENERATES, so the difference can be negative - saying
			-- "it cost -17.6" is exactly the kind of number that reads like a
			-- bug. Only a spend is reported as a cost.
			local spent = (preStam ~= nil and postStam ~= nil) and (preStam - postStam) or nil
			log(string.format("REFUSED %s - the game took the press and did not dash. %s", name,
				(spent ~= nil and spent > 0.5) and string.format("It cost %.1f stamina, so the next press in this window is still worth sending.", spent)
					or "Refusals are close to free, so the next press in this window is still worth sending."))
		end
		-- the outcome, on the same clock as the press. The old engine scored
		-- this from its landing watch; the startup engine needs it to say
		-- anything about whether the dodge worked.
		local h2, m2, p2 = health(), meter(), lastPerfect()
		local hurt = (preH ~= nil and h2 ~= nil and h2 < (preH - 0.5))
		local moved = (preM ~= nil and m2 ~= nil and m2 > (preM + 0.5))
			or (preP ~= nil and p2 ~= nil and p2 ~= preP)
		counters.exchanges = counters.exchanges + 1
		if hurt then
			counters.hit = counters.hit + 1
			-- this read happens once, %.0fms is the AGE OF THE READ, not the
			-- punch's landing time - saying "it landed at 571ms" was wrong and
			-- read as a measurement it had not made
			log(string.format("TOOK DAMAGE %s within %.0fms of the press (the read is one sample, so this says the window failed, not when).", name, (now() - (pressedAt or now())) * 1000))
		elseif moved then
			counters.perfect = counters.perfect + 1
			log(string.format("PERFECT %s - no damage and the meter moved.", name))
		else
			counters.clean = counters.clean + 1
		end
	end)
end

local function startupTick(opp)
	local edge = nil
	if cfg.startupClock then edge = hlEdge(opp) end
	local nowT = now()
	if edge ~= nil then
		HL.dueAt = edge + (cfg.startupMs / 1000)
		SLOP.lastPress = nil
		SLOP.counterAt = nil
	end
	-- THE CONDITION IS THE SCRIPT'S OWN CONDITION: the instance is up. Nothing
	-- else is asked before the press except "am I on a canvas" and "have I the
	-- stamina to pay for it" - no dash-gap gate, no fuse arithmetic, no token.
	if not HL.on then return end
	-- THE COUNTER'S HOLD. A fake leaves the highlight up, so without this the
	-- repeat press would dodge the fake about 110ms after the counter saved the
	-- dodge. It ends on the first of: a new highlight edge (handled above), a
	-- NEW opponent Swing/SwingBig sound - which is the real punch behind the
	-- fake, written ~130ms after that punch starts - or the ceiling.
	if SLOP.counterAt ~= nil then
		local swingSince = (SND.lastSwingAt ~= nil and SND.lastSwingAt >= SLOP.counterAt)
		if swingSince or (nowT - SLOP.counterAt) >= (cfg.counterHoldOffMs / 1000) then
			SLOP.counterAt = nil
		else
			return
		end
	end
	local due = HL.dueAt or (nowT - 1)
	if nowT < due then return end
	if SLOP.lastPress ~= nil and (nowT - SLOP.lastPress) < (cfg.startupRepeatMs / 1000) then return end
	if not cfg.auto then return end
	if cfg.requireRink then
		local inside = inRink()
		RINK.last = inside
		if inside == false then
			counters.rinkSkip = counters.rinkSkip + 1
			if counters.rinkSkip == 1 then
				log("OUTSIDE THE RINK: the opponent is still locked on and still throwing, but this character is not on a canvas - nothing is pressed until you step in.")
			end
			return
		end
	end
	local st = stamina()
	if cfg.minStamina > 0 and st ~= nil and st < cfg.minStamina then return end
	SLOP.lastPress = nowT
	local name = opp and opp.name or "?"
	local offset = (nowT - (HL.at or nowT)) * 1000
	-- THE FEINT, in the order the tells arrive:
	--   1. the feint SOUND (~50ms after the attempt - measured),
	--   2. the IsFeinting stamp (330-400ms after it - measured),
	-- and the answer to either is the same one a feint is designed to prevent:
	-- no dodge is spent, a PUNCH goes out into the recovery, and the real punch
	-- behind the fake still gets its own edge and its own dodge.
	if cfg.antiFeint or cfg.counter then
		local f, tag = nil, nil
		if cfg.counter and cfg.soundCues then
			f = soundFeint()
			if f ~= nil then tag = "sound" end
		end
		if f == nil and cfg.antiFeint and cfg.feintStamp then
			-- the same fake arriving late: the sound already answered it
			if ANSWERED.at ~= nil and (nowT - ANSWERED.at) < (cfg.feintOnceMs / 1000) then
				ANSWERED.skips = ANSWERED.skips + 1
			else
				f = feintLive()
				if f ~= nil then tag = "stamp" end
			end
		end
		if f ~= nil then
			SLOP.feints = SLOP.feints + 1
			counters.feint = counters.feint + 1
			counters.feintHl = counters.feintHl + 1
			if tag == "sound" then
				counters.feintSound = counters.feintSound + 1
			else
				counters.feintStamp = counters.feintStamp + 1
			end
			if cfg.counter then
				-- no dodge for the rest of THIS attempt: see counterHoldOffMs and
				-- the release in startupTick. The real punch behind the fake is a
				-- new edge (or its own Swing sound), and either one ends the hold.
				SLOP.lastPress = nowT
				SLOP.counterAt = nowT
				ANSWERED.at = nowT
				counterPunch(name, f)
			else
				log(string.format("FEINT %s at +%.0fms of the startup highlight - %s. NO PRESS: the short script in the wild dodges this fake, and that is the whole difference. The punch behind it gets its own edge.",
					name, offset, f))
			end
			return
		end
	end
	startupPress(opp, name, offset)
end

local function tick()
	local opp = refresh()
	if opp == nil then return end
	-- the sound cues are polled once per tick, before either engine looks at
	-- the attempt: a feint cue is written ~50ms after the fake starts, so it has
	-- to be seen on the same tick the press decision is made on
	sndPoll(opp.name)
	-- the attempt clock the sound tell is judged against (one attribute read)
	local tokNow = readToken(opp.model)
	if tokNow ~= nil and tokNow ~= TOKN.v then TOKN.v, TOKN.at = tokNow, now() end
	if cfg.engine == "startup" then return startupTick(opp) end
	-- THE EDGE IS READ FIRST, before any attribute. It is one exists-check, so
	-- it is the cheapest thing in this tick, and starting the clock on it means
	-- the window begins before the token's reads rather than after them.
	local edge = nil
	if cfg.startupClock then edge = hlEdge(opp) end
	local tok, heavy, hand = readToken(opp.model)
	local fresh = (tok ~= nil and tok ~= WORLD.tok)
	if edge == nil and not fresh then return end
	if fresh then WORLD.tok = tok end
	if not cfg.auto then return end
	-- THE RINK GATE. The token is published whether or not this character is in
	-- the fight, so the only honest question is where the character is standing.
	if cfg.requireRink then
		local inside = inRink()
		RINK.last = inside
		if inside == false then
			counters.rinkSkip = counters.rinkSkip + 1
			if counters.rinkSkip == 1 then
				log("OUTSIDE THE RINK: the opponent is still locked on and still throwing, but this character is not on a canvas - nothing is pressed until you step in.")
			end
			return
		end
	end
	local ok, err = pcall(exchange, tok, heavy, hand, edge and "startup" or "token", edge)
	if not ok then
		warn("exchange error (ignored, the loop keeps going): " .. tostring(err))
	end
end

local function timingLine()
	local m = medianOf(counters.poff)
	return string.format("timing: press offset median %s (n=%d) | dash latency %s (%d sample(s)) | %s",
		m and string.format("%.0fms", m) or "?", #counters.poff,
		LAT.median and (LAT.median .. "ms") or ("unmeasured, using " .. cfg.dashUpMs .. "ms"),
		LAT.n, dirScoreLine())
end

local function rinkWord()
	-- asked live rather than remembered: status is a debugging call, and a "?"
	-- that only clears on the next token is worse than one extra read
	RINK.last = inRink()
	if RINK.last == true then return "in" end
	if RINK.last == false then return "out" end
	return "?"
end

local function statusLine()
	return string.format(
		"exchanges=%d presses=%d reg=%d refused=%d | PERFECT=%d HIT=%d CLEAN=%d late=%d skips=%d | dir ok=%d bad=%d ?=%d | needed used=%d moved=%d | feints=%d rearm=%d cover=%d retry=%d | stun wait=%d held=%d stale=%d | fireMs=%d | keys sent=%d failed=%d | lines=%d",
		counters.exchanges, counters.presses, counters.registered, counters.unregistered,
		counters.perfect, counters.hit, counters.clean, counters.late, counters.skipped,
		counters.dirOk, counters.dirBad, counters.dirUnknown,
		counters.neededUsed, counters.neededMoved,
		counters.feint, counters.rearm, counters.cover, counters.retry,
		counters.stunWait, counters.stunHeld, counters.stalePress,
		cfg.fireMs, INPUT.sent, INPUT.failed, WATCH.n)
		.. string.format(" | rink=%s withheld=%d | feint-waited=%d of %d (patience %dms, cut %s)",
			rinkWord(), counters.rinkSkip, counters.feintWait, counters.exchanges,
			cfg.feintPatienceMs, FEINT.cutAt and "yes" or "no")
		.. string.format(" | startup edges=%d presses=%d feint-cancels=%d",
			HL.seen, counters.hlPress, counters.feintHl)
		.. string.format(" | engine=%s edges=%d presses=%d reg=%d refused=%d feint-skips=%d",
			cfg.engine, HL.seen, SLOP.presses, SLOP.reg, SLOP.refused, SLOP.feints)
		.. string.format(" | sound cues=%d feint-cues=%d stale=%d | counter fired=%d landed=%d missed=%d (tell: sound=%d stamp=%d, repeats skipped=%d)",
			SND.n, SND.feints, SND.stale, counters.counter, counters.counterHit, counters.counterMiss,
			counters.feintSound, counters.feintStamp, ANSWERED.skips)
		.. string.format(" | keys dash=%s (%s) counter=%s",
			tostring(cfg.dodgeKey), tostring(KEYS.from), tostring(cfg.counterKey))
end

local LOOP = { started = false }

-- the loop is startable, not just started: stop() is terminal for the thread it
-- kills, so on() has to be able to bring a new one up or it lies about it.
local function startLoop()
	if LOOP.started and running then return end
	running = true
	LOOP.started = true
	task.spawn(function()
		while running do
			local ok, err = pcall(tick)
			if not ok then warn("loop error (ignored): " .. tostring(err)) end
			if (now() - lastStatus) > (cfg.statusMs / 1000) then
				lastStatus = now()
				log("alive: " .. statusLine())
				log("  " .. timingLine())
			end
			wait(cfg.pollMs / 1000)
		end
	end)
end

--=============================== CONSOLE ===================================
local D = {}
_G.D = D
-- muscle memory: the old file answered to _G.PD, and so does this one
_G.PD = D

function D.on()
	cfg.auto = true
	startLoop()
	log("auto dodge ON")
end

function D.off()
	cfg.auto = false
	log("auto dodge OFF")
end

function D.stop()
	running = false
	cfg.auto = false
	pcall(releaseAll)
	log("stopped.")
end

function D.release()
	releaseAll()
	log("released every key: " .. keySnap())
end

function D.status()
	print("[D] " .. statusLine())
	print("[D] " .. timingLine())
	print("[D] " .. ledgerLine())
	print("[D] " .. hlLine())
	local blocked, why = stunVerdict()
	print(string.format("[D] stun: %s (%s)", blocked and "REFUSING" or "clear", why))
	print("[D] " .. capsLine())
	print(string.format("[D] services: Players=%s via %s", tostring(PLR ~= nil),
		PLR and ((pcall(function() return game:GetService("Players") end) and "GetService") or "game.Players") or "MISSING"))
	print("[D] " .. INPUT.verdict)
	print(string.format("[D] press=%s shape=%s  auto=%s  keys-you: %s",
		cfg.pressMode, tostring(shapeNow()), tostring(cfg.auto), keySnap()))
	wrecord("[D] " .. statusLine())
end

function D.show()
	local names = {}
	for k in pairs(cfg) do names[#names + 1] = k end
	table.sort(names)
	for _, k in ipairs(names) do
		local v = cfg[k]
		if type(v) == "table" then
			local parts = {}
			for kk, vv in pairs(v) do parts[#parts + 1] = tostring(kk) .. "=" .. tostring(vv) end
			v = "{" .. table.concat(parts, ", ") .. "}"
		end
		print(string.format("[D]   %-18s = %s", k, tostring(v)))
	end
end

function D.set(key, value)
	if key == nil then return D.show() end
	if cfg[key] == nil then
		warn("no setting called " .. tostring(key) .. " - _G.D.show() lists them")
		return
	end
	cfg[key] = value
	log(string.format("set %s = %s", tostring(key), tostring(value)))
	if key == "fireMs" or key == "fusePerOpp" then
		log(string.format("  note: the per-opponent fuse overrides fireMs for any opponent with %d+ measured landings. _G.D.set(\"fusePerOpp\", false) makes fireMs the only fuse.", cfg.fusePerOppMin))
	end
	return value
end

function D.caps()
	capsProbe()
	print("[D] " .. capsLine())
	print(string.format("[D] Instance=%s  getgc=%s  hookfunction=%s",
		tostring(_G.Instance ~= nil), tostring(_G.getgc ~= nil), tostring(_G.hookfunction ~= nil)))
	print("[D] this script never scans the heap and never constructs an instance - it reads attributes only.")
	return ENV
end

function D.keytest()
	return keytest(false)
end

-- which copy of the file is actually loaded
function D.build()
	print(string.format("[D] BUILD %s | requireRink=%s margin=%d | feintPatience=%dms | autoKeyTest=%s | fireMs=%d | spinMs=%d",
		BUILD, tostring(cfg.requireRink), cfg.rinkMargin, cfg.feintPatienceMs,
		tostring(cfg.autoKeyTest), cfg.fireMs, cfg.spinMs))
	print(string.format("[D]   archive: %s", tostring(_G.D == D and "this instance owns _G.D" or "another instance has replaced _G.D")))
	return BUILD
end

function D.stun()
	local flag = stunFlag()
	local until_ = stunUntil()
	local srv = serverNow()
	local blocked, why, left = stunVerdict()
	print(string.format("[D] Stunned=%s  StunnedUntil=%s  serverNow=%s", tostring(flag), tostring(until_), tostring(srv)))
	if until_ ~= nil and srv ~= nil then
		print(string.format("[D] deadline is %+.2fs from now", until_ - srv))
	end
	print(string.format("[D] VERDICT: %s - %s", blocked and "REFUSING" or "clear", why))
	print(string.format("[D] presses let through on a stale flag: %d; waits=%d held=%d",
		counters.stalePress, counters.stunWait, counters.stunHeld))
	return blocked, why
end

function D.side(hand)
	local h = hand or attr(WORLD.oppModel, "AttackingHand") or "RightHand"
	local base = sideFor(h)
	local out = string.format("%s -> %s (handMap + dirRule=%s)", tostring(h), base, cfg.dirRule)
	local nd = neededSide()
	if cfg.dirSource == "needed" and (nd == "left" or nd == "right") then
		out = out .. string.format("; the game says %s, so the key would be %s", nd, nd)
	elseif nd ~= nil then
		out = out .. string.format("; the game says %s (not steering, dirSource=%s)", nd, cfg.dirSource)
	end
	print("[D] " .. out)
	return base
end

function D.dir(side)
	local base = side or "left"
	local key = keyFor(base)
	press(key, true, "manual")
	local until_ = now() + (cfg.preholdMs / 1000)
	while now() < until_ do wait(0.005) end
	local pre = { last = lastDashTime(), stam = stamina(), dir = cachedDir(), inv = dashInvuln() }
	tapFor(cfg.dodgeKey, cfg.pressHoldMs)
	press(key, false, "manual")
	local pressedAt = now()
	local reg, how = false, nil
	local until2 = pressedAt + (cfg.confirmMs / 1000)
	while now() < until2 do
		local r, w = registeredSince(pre)
		if r then reg, how = true, w; break end
		wait(0.01)
	end
	local dirNow, want = score(base, pre, pressedAt)
	print(string.format("[D] manual %s (%s): %s | stored %s, wanted %s | %s",
		base, key, reg and ("REGISTERED - " .. tostring(how)) or "NOT REGISTERED",
		tostring(dirNow or "?"), want, ledgerLine()))
	return reg
end

function D.presstest()
	local pre = lastDashTime()
	if pre == nil then
		warn("PRESSTEST needs the character's LastDashTime - _G.D.dump() shows whether it is readable.")
		return false
	end
	log(string.format("PRESSTEST: one %s press, judged by the game's own LastDashTime. No opponent, no timing.", tostring(cfg.dodgeKey)))
	press(cfg.dodgeKey, true, "test")
	local hold = now() + (cfg.pressHoldMs / 1000)
	while now() < hold do end
	press(cfg.dodgeKey, false, "test")
	local until_ = now() + 0.6
	local moved = false
	while now() < until_ do
		local l = lastDashTime()
		if l ~= nil and l ~= pre then moved = true; break end
		wait(0.005)
	end
	if moved then
		INPUT.state = "working"
		INPUT.verdict = "the press WORKS - the game logged a dash (proven by LastDashTime)"
		log("PRESSTEST: the press WORKS. The game logged a dash, so the shape and the argument are right.")
		return true
	end
	INPUT.state = "unverified"
	warn("PRESSTEST: the game did not log a dash. It can be a dead press OR a refused one - stamina, an active dash or spam. _G.D.stun() and the stamina in _G.D.status() say which.")
	return false
end

-- the feint question, answered with the numbers it used
function D.feint()
	local raw = attr(WORLD.oppModel, "IsFeinting")
	local srv = serverNow()
	local gameAge = (raw ~= nil and type(raw) == "number" and srv ~= nil) and (srv - raw) or nil
	print(string.format("[D] FEINT: stamps seen=%d live-marked=%d cancelled=%d | patience=%dms applied=%d | cut=%s",
		FEINT.seen, FEINT.marked, counters.feint, cfg.feintPatienceMs, counters.feintWait,
		FEINT.cutAt and string.format("yes, last cut %+.1fs ago", now() - FEINT.cutAt) or "no"))
	print(string.format("[D]   IsFeinting=%s  my game clock=%s  (game age %s)  freeze hits=%d",
		tostring(raw), srv and string.format("%.2f", srv) or "?",
		gameAge and string.format("%+.0fms", gameAge * 1000) or "?", FEINT.clockMiss))
	if FEINT.seenAt ~= nil then
		print(string.format("[D]   last NEW stamp first seen %+.0fms ago - that is the age that cannot freeze", (now() - FEINT.seenAt) * 1000))
	end
	return FEINT.seen, counters.feint
end

-- the keys the game actually binds, read out of its own widget
function D.key()
	readKeybinds(false)
	print(string.format("[D] dash=%s  counter=%s  heavy=%s  block=%s  quick=%s   (from %s)",
		tostring(cfg.dodgeKey), tostring(cfg.counterKey), tostring(KEYS.heavy or "?"),
		tostring(KEYS.block or "?"), tostring(KEYS.quick or "?"), tostring(KEYS.from)))
	if KEYS.read < 2 then
		print("[D]   only " .. tostring(KEYS.read) .. " bind(s) could be read. The widget is built on load; if it is missing, open the menu once and call this again. The cfg default is " .. tostring(cfg.dodgeKey) .. ".")
	end
	return cfg.dodgeKey, cfg.counterKey
end

-- the sound cues: what the game wrote, when, and which tell is live
function D.snd(tail)
	local root = sndDebris()
	print(string.format("[D] SOUND: Debris=%s cues=%d scans=%d | feint-cues=%d swings=%d hits=%d",
		root and "yes" or "NO", SND.n, SND.scans, SND.feints, SND.swings, SND.hits))
	if SND.lastFeintAt ~= nil then
		print(string.format("[D]   last feint cue %s %+.0fms ago; it stays actionable for %dms (soundFeintWindowMs). Counter key %s.",
			tostring(SND.lastFeintName), (now() - SND.lastFeintAt) * 1000, cfg.soundFeintWindowMs, tostring(cfg.counterKey)))
	end
	print(string.format("[D]   counters fired=%d landed=%d missed=%d | tells: sound=%d stamp=%d",
		counters.counter, counters.counterHit, counters.counterMiss, counters.feintSound, counters.feintStamp))
	local n = tonumber(tail) or 8
	local from = math.max(1, #SND.cues - n + 1)
	for i = from, #SND.cues do
		local c = SND.cues[i]
		print(string.format("[D]   %+7.0fms  %-22s %s", (now() - c.t) * 1000, tostring(c.n), tostring(c.h)))
	end
	if root == nil then
		print("[D]   workspace.Debris is not there - the sound path is dead in this place, and the IsFeinting stamp is the only feint tell left.")
	end
	return SND.n
end

-- one counter-punch, on demand: the same code the feint path runs
function D.counter()
	local name = (WORLD.opp ~= nil and WORLD.opp.name) or "?"
	if WORLD.opp == nil then
		warn("COUNTER test with no opponent: the punch still goes out, but nothing will confirm a hit. Use it in a fight.")
	end
	counterPunch(name, "manual test (no feint)")
	return true
end

-- the rink gate, answered with the numbers it used
function D.rink()
	local parts = rinkParts()
	local inside = inRink()
	print(string.format("[D] RINK: %s | %d canvas(es) readable, margin %d studs, requireRink=%s",
		inside == true and "INSIDE" or (inside == false and "OUTSIDE" or "UNKNOWN (nothing readable)"),
		#parts, cfg.rinkMargin, tostring(cfg.requireRink)))
	local p = posOf(rootOf(myModel()))
	if p ~= nil then
		print(string.format("[D]   my root %.1f, %.1f, %.1f", p.x, p.y, p.z))
		for i, c in ipairs(parts) do
			print(string.format("[D]   canvas %d: centre %.1f, %.1f, %.1f  half %.1f x %.1f  off by %.1f, %.1f",
				i, c.x, c.y, c.z, c.hx, c.hz, p.x - c.x, p.z - c.z))
		end
	else
		print("[D]   no character root readable")
	end
	print(string.format("[D] presses withheld for being outside the rink: %d", counters.rinkSkip))
	return inside
end

function D.spam()
	print(string.format("[D] DashSpamLevel at presses: %s", rangeOf(SPAM.press)))
	print(string.format("[D] DashSpamLevel at registrations: %s", rangeOf(SPAM.reg)))
	print(string.format("[D] gate: maxSpamLevel=%s (nil = off). Set it only from the numbers above.",
		tostring(cfg.maxSpamLevel)))
end

function D.dirs()
	print("[D] " .. dirScoreLine())
	print(string.format("[D] the default side is dirSource=%s; dirAuto=%s (>=8 judged, >=3 perfects, 3-perfect lead), fist fallback=%s",
		tostring(cfg.dirSource), tostring(cfg.dirAuto), tostring(cfg.dirFistFallback)))
	print(string.format("[D] last press would have used: %s", tostring(D.side() or "?")))
end

function D.hl(name)
	if type(name) == "string" then
		-- asked about a name rather than the current opponent: does that rig
		-- even have the instance right now? This is the live check the notes
		-- kept asking for - only existence is readable, so existence is what
		-- gets reported.
		local rig = hlRigFor(nil, name)
		local sh = nil
		pcall(function() sh = rig and rig:FindFirstChild("StartupHighlight") end)
		print(string.format("[D] weld rig %s: %s, StartupHighlight=%s", name,
			rig and "found" or "MISSING", tostring(sh ~= nil)))
		return
	end
	print("[D] " .. hlLine())
	local fire = medianOf(HL.fire)
	local lead = medianOf(HL.lead)
	print(string.format("[D]   startupMs=%d learned-here=%s  token-lag=%s  (the delay is learned from landings measured from the edge, per opponent)",
		cfg.startupMs,
		fire and string.format("%.0fms over %d press(es)", fire, #HL.fire) or "not yet",
		lead and string.format("%.0fms (n=%d)", lead, #HL.lead) or "not yet"))
	local names = {}
	for k in pairs(LAND.data) do names[#names + 1] = k end
	table.sort(names)
	for _, k in ipairs(names) do
		local row = LAND.data[k]
		local hf = medianOf(row.hl)
		local tf = medianOf(row.light)
		if hf ~= nil or tf ~= nil or row.hlFire ~= nil or row.fuse ~= nil then
			print(string.format("[D]   %-18s startup: landing %s -> delay %s | token: landing %s -> fuse %s", k,
				hf and string.format("%.0fms", hf) or "-", row.hlFire and (row.hlFire .. "ms") or "-",
				tf and string.format("%.0fms", tf) or "-", row.fuse and (row.fuse .. "ms") or "-"))
		end
	end
	if hlSetting() == false then
		print("[D]   ShinyStartups reads OFF - but this build still parents the highlight with it off (measured live), so the edge is in use regardless. It is reported, not gated on.")
	end
end

function D.land()
	if next(LAND.data) == nil then
		print("[D] no landings measured yet - they are recorded from punches that actually hit you.")
		return
	end
	for name, row in pairs(LAND.data) do
		print(string.format("[D] %-20s light=%s heavy=%s fuse=%s heavy fuse=%s",
			name,
			medianOf(row.light) and string.format("%.0fms (n=%d)", medianOf(row.light), #row.light) or "-",
			medianOf(row.heavy) and string.format("%.0fms (n=%d)", medianOf(row.heavy), #row.heavy) or "-",
			row.fuse and ("+" .. tostring(row.fuse)) or "fireMs",
			row.fuseHeavy and ("+" .. tostring(row.fuseHeavy)) or "same"))
	end
end

function D.fuse(name)
	if name == nil then
		for n, row in pairs(LAND.data) do
			print(string.format("[D] %-20s -> %d", n, row.fuse or cfg.fireMs))
		end
		return
	end
	return landOf(name).fuse or cfg.fireMs
end

function D.dump()
	local opp = WORLD.opp
	print("[D] me: " .. tostring(myName()))
	local m = myModel()
	if m ~= nil then
		for _, k in ipairs({ "LastDashTime", "LocalCompensatedTime", "TimeBetweenDash",
			"DashSpamLevel", "NeededDirection", "CachedDashDirection",
			"LastPerfectDodged", "DashInvulnerable", "Stunned", "StunnedUntil" }) do
			local v, ok = attr(m, k)
			print(string.format("[D]   me.%-20s = %s%s", k, tostring(v), ok and "" or "  (unreadable)"))
		end
	end
	for _, k in ipairs({ "Dashing", "Stamina", "Stunned", "PerfectDodgeMeter", "Health" }) do
		print(string.format("[D]   state.%-17s = %s", k, tostring(valueOf(myName(), k))))
	end
	if opp == nil then
		print("[D] no opponent.")
		return
	end
	print(string.format("[D] foe %s (%s) dist=%s", opp.name, opp.how,
		opp.dist and string.format("%.1f", opp.dist) or "?"))
	local tok, heavy, hand = readToken(opp.model)
	print(string.format("[D]   TryAttack=%s IsHeavy=%s AttackingHand=%s",
		tostring(tok), tostring(heavy), tostring(hand)))
	for _, k in ipairs({ "IsFeinting", "ConfirmedFeintRequestId", "Health" }) do
		local v, ok = attr(opp.model, k)
		print(string.format("[D]   foe.%-19s = %s%s", k, tostring(v), ok and "" or "  (unreadable)"))
	end
	local on, show = frameAt(opp.model)
	print(string.format("[D]   fist frame: %s (%s)", tostring(on), tostring(show)))
end

local function transcript(limit)
	local total = #WATCH.lines
	local from = 1
	if limit ~= nil and limit > 0 and total > limit then from = total - limit + 1 end
	local out = {}
	for i = from, total do out[#out + 1] = WATCH.lines[i] end
	return table.concat(out, "\n")
end

function D.keys(limit)
	print(transcript(limit or 80))
end

function D.copy(limit)
	local text = transcript(limit or cfg.copyLines)
	local ok = false
	if ENV.setclipboard ~= nil then
		ok = pcall(function() ENV.setclipboard(text) end)
	end
	local file = false
	if ENV.writefile ~= nil then
		file = pcall(function() ENV.writefile("ubg_dodge_run.txt", text) end)
	end
	print(string.format("[D] %d lines%s%s", #WATCH.lines,
		ok and " copied to the clipboard" or " NOT copied (no clipboard)",
		file and ", also written to ubg_dodge_run.txt" or ""))
	return text
end

D.watch = function(mode)
	if mode == false then
		WATCH.paused = true
		print("[D] transcript paused")
	else
		WATCH.paused = false
		print("[D] transcript recording")
	end
end

D.clear = function()
	WATCH.lines = {}
	WATCH.n = 0
	print("[D] transcript cleared")
end

D.tick = tick
D.config = cfg
D.counters = counters

--================================= BOOT ====================================
pcall(capsProbe)
-- THE KEYS ARE READ BEFORE ANYTHING IS PRESSED. Build 4 pressed Space for a
-- whole session against a game that binds Dash to X; the widget is the
-- authority and it costs six FindFirstChild calls here.
if cfg.readKeybinds then pcall(readKeybinds, false) end
if cfg.watchKeys then pcall(keyTestListen) end

if ENV.keypress == nil and ENV.vim == nil then
	warn("this build has neither keypress/keyrelease nor VirtualInputManager - nothing here can press a key.")
	warn("  _G.D.caps() lists what does exist. There is no remote fallback in this file on purpose: the remote layer in this executor is a local stub that answers true to everything.")
	running = false
	return D
end

log("BOXING DODGE v2 - a rewrite, not another restart.")
log("  build: " .. BUILD)
log("  " .. capsLine())
log(string.format("  fuse: fireMs=%d (+%d heavy, only when measured late), per-opponent after %d landings, floor %dms while antiFeint is on",
	cfg.fireMs, cfg.heavyExtraMs, cfg.fusePerOppMin, cfg.feintGuardMs))
log(string.format("  feints: patience +%dms against an opponent that has already feinted, cut back to the room their measured landing leaves. _G.D.feint() shows the stamps and the clock.",
	cfg.feintPatienceMs))
log(string.format("  startup: %s - the game's own StartupHighlight is the clock when it exists (ShinyStartups reads %s, and the highlight appears either way; delay %dms until this opponent's landings replace it). The feint veto runs before the press, which is the one thing the short script in the wild cannot do. _G.D.hl() reports it.",
	cfg.startupClock and "ON" or "off", tostring(hlSetting()), cfg.startupMs))
log(string.format("  engine: %s%s", cfg.engine,
	cfg.engine == "startup"
		and string.format(" - press on the StartupHighlight edge at +%dms, bare %s held %dms, again every %dms while it is up; ONLY two things can withhold it: not being on a canvas, and stamina below %d. No dash-gap gate: it withheld 8 windows and dropped registration from ~60%% to 24%% in one measured fight.", cfg.startupMs, tostring(cfg.dodgeKey), cfg.startupHoldMs, cfg.startupRepeatMs, cfg.minStamina)
		or string.format(" - the fuse engine: token clock, fireMs=%d, minDashGapMs=%d, spam>=%s", cfg.fireMs, cfg.minDashGapMs,
			cfg.maxSpamLevel and string.format("%.2f", cfg.maxSpamLevel) or "off")))
log(string.format("  sound: %s - the game's own cues in Workspace.Debris. A feint writes Feint + Feint2 + FeintRustle into Debris.SoundPart ~50ms after the attempt (measured live), against 330-400ms for the IsFeinting stamp, so the feint tell is now the sound. _G.D.snd() lists the tail, _G.D.set(\"soundCues\", false) turns it off.", cfg.soundCues and "ON" or "off"))
log(string.format("  counter: %s - a feint is answered with %s (light attack, read from the keybinds) instead of a dodge: a fake has no hitbox, so the punch is free, and a second one goes out if the first produces no impact sound. The game's own hit sound says COUNTER LANDED. _G.D.counter() fires one by hand.", cfg.counter and "ON" or "off", tostring(cfg.counterKey)))
log(string.format("  direction: %s at the press, %s through the pre-hold every %dms; base mapping %s + dirRule=%s, so LeftHand -> %s key",
	cfg.dirSource, cfg.neededPoll and "re-read" or "not re-read", cfg.neededPollMs,
	"handMap", cfg.dirRule, tostring(sideFor("LeftHand"))))
log(string.format("  press: one shape (%s), prehold %dms, hold %dms, spin the last %dms. No shape is trusted until keytest proves it.",
	tostring(cfg.pressShape), cfg.preholdMs, cfg.pressHoldMs, cfg.spinMs))
log(string.format("  rink: %s - the press waits for the character to be over a canvas in workspace.Rings (%d readable, margin %d studs). _G.D.rink() answers it.",
	cfg.requireRink and "GATED" or "off (presses anywhere)", #rinkParts(), cfg.rinkMargin))
log("  watch: every SEND and every real key edge is recorded - _G.D.keys(80) for the tail, _G.D.copy() for the lot.")
log("  after a fight: _G.D.status()  then  _G.D.copy()  and paste the clipboard back.")
log("  nothing here scans the heap or constructs an instance; it reads about a dozen attributes per tick.")

if cfg.autoKeyTest then
	task.spawn(function()
		local until_ = now() + (cfg.keyTestAtMs / 1000)
		while running and now() < until_ do wait(0.05) end
		if running and cfg.pressLock == nil then pcall(keytest, true) end
	end)
end

startLoop()

log("running. Fight one person in the rink - the opponent value is empty in the lobby.")
pcall(releaseAll)
return D
