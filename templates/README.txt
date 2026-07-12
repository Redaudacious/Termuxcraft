==================================================================
  README  —  preparing the Minecraft server inside this VM
==================================================================

This VM ships INTENTIONALLY WITHOUT Java (JDK) installed, so the
system stays clean and the installer picks exactly the right Java.

You choose ONE server flavour:

    Fabric  ->  bash ~/fabric-installer.sh   (mods, most customizable)
    Paper   ->  bash ~/paper-installer.sh    (plugins, fastest OOTB)

Pick one per VM. Do NOT install both into the same ~/server folder —
Fabric uses mods/, Paper uses plugins/, and they will not mix.

------------------------------------------------------------------
1. WHICH JAVA VERSION?
------------------------------------------------------------------
    Minecraft 1.20.5 - 1.21.x   ->  Java 21
    Minecraft 1.18   - 1.20.4   ->  Java 17
    Minecraft 1.17              ->  Java 16
    Minecraft 1.16 and older    ->  Java 8

Both installers download Java 21 automatically (for 1.21.x).

------------------------------------------------------------------
2. THE FAST PATH (RECOMMENDED)
------------------------------------------------------------------
  FABRIC:
    bash ~/fabric-installer.sh
    Downloads (locally into ~/server/jdk, system stays clean):
      - Java 21 (Temurin, aarch64)
      - Fabric server for the target version
      - performance + utility mods: Fabric API, Lithium, FerriteCore,
        Krypton, C2ME, Chunky, ServerCore, spark, Noisium, ScalableLux,
        ModernFix, Clumps, Alternate Current

  PAPER:
    bash ~/paper-installer.sh
    Downloads (locally into ~/server/jdk):
      - Java 21 (Temurin, aarch64)
      - the latest Paper build for the target version
      - plugins: Chunky (pre-generator) and spark (profiler)
    Paper already includes most of Fabric's performance tweaks, and
    the installer switches redstone to ALTERNATE_CURRENT in
    config/paper-global.yml.

The target Minecraft version and port come from /root/vm.env, which
the setup wrote for you. Change them from the phone with:
    commands vm <name>      (RAM, ports, auth, Cloudflare, playit)

------------------------------------------------------------------
3. ACCEPT THE EULA (MANDATORY)
------------------------------------------------------------------
The nanny will NOT start the server until you do this:

    nano ~/server/eula.txt      # change eula=false -> eula=true

Save (Ctrl+O, Enter) and exit (Ctrl+X). The nanny then starts the
server automatically in ~10-20 seconds.

------------------------------------------------------------------
4. WHERE THE FILES LIVE
------------------------------------------------------------------
    ~/server/                          -> world + config
    ~/server/jdk/bin/java              -> Java used at startup
    ~/server/fabric-server-launch.jar  -> Fabric jar (if Fabric)
    ~/server/paper-*.jar               -> Paper jar (if Paper)
    ~/server/mods/                     -> Fabric mods (.jar)
    ~/server/plugins/                  -> Paper plugins (.jar)
    /root/vm.env                       -> RAM / ports / MC version

Bring your own world/mods/plugins by dropping them into ~/server/,
~/server/mods/ or ~/server/plugins/.

------------------------------------------------------------------
5. THE SERVER CONSOLE
------------------------------------------------------------------
    tmux attach -t mc-server   -> enter the console
    Ctrl+B then D              -> leave WITHOUT stopping the server
    type 'stop' in the console -> stop the server cleanly
==================================================================
