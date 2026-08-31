import Darwin
import Foundation

nonisolated enum SandboxContainerProtection {
    static func permits(_ identifier: String) -> Bool {
        let normalized = identifier.lowercased()
        let ownIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        if let ownIdentifier,
           (normalized == ownIdentifier || normalized.hasPrefix(ownIdentifier + ".")) {
            return false
        }
        guard !normalized.isEmpty,
              !normalized.hasPrefix("com.apple."),
              !criticalFragments.contains(where: normalized.contains),
              !protectedPatterns.contains(where: { matches(normalized, pattern: $0) }) else {
            return false
        }
        return true
    }

    private static func matches(_ identifier: String, pattern: String) -> Bool {
        pattern.withCString { patternPointer in
            identifier.withCString { identifierPointer in
                fnmatch(patternPointer, identifierPointer, 0) == 0
            }
        }
    }

    private static let criticalFragments = [
        "backgroundtaskmanagement", "loginitems", "systempreferences", "systemsettings",
        "settings", "preferences", "controlcenter", "biometrickit", "sfl", "tcc"
    ]

    private static let protectedPatterns = [
        "loginwindow", "dock", "finder", "safari", "keychain*", "security*", "bluetooth*",
        "wifi*", "network*", "notification*", "accessibility*", "universalaccess*", "hitoolbox*",
        "*inputmethod*", "*ime", "textinput*", "keyboard*", "inputsource*", "keylayout*",
        "globalpreferences", ".globalpreferences", "org.cups.*", "org.pqrs.karabiner*",

        "com.tencent.inputmethod.qqinput", "com.sogou.inputmethod.*", "com.baidu.inputmethod.*",
        "com.googlecode.rimeime.*", "im.rime.*", "com.nektony.*", "com.macpaw.*",
        "com.freemacsoft.appcleaner", "com.omnigroup.omnidisksweeper", "com.daisydiskapp.*",
        "com.tunabellysoftware.*", "com.grandperspectiv.*", "com.binaryfruit.*",

        "com.1password.*", "com.agilebits.*", "com.lastpass.*", "com.dashlane.*",
        "com.bitwarden.*", "com.keepassx.*", "org.keepassx.*", "org.keepassxc.*",
        "com.authy.*", "com.yubico.*",

        "com.jetbrains.*", "jetbrains*", "com.microsoft.*", "com.visualstudio.*",
        "com.sublimetext.*", "com.sublimehq.*", "com.coteditor.coteditor",
        "com.macromates.textmate", "com.panic.nova", "abnerworks.typora", "com.uranusjr.macdown",
        "com.todesktop.*", "cursor", "com.anthropic.claude*", "claude", "codex-runtimes",
        "com.ollama.ollama", "ollama", "com.lmstudio.lmstudio", "lm studio",
        "co.supertool.chatbox", "page.jan.jan", "com.huggingface.huggingchat", "gemini",
        "com.perplexity.perplexity", "com.drawthings.drawthings", "com.divamgupta.diffusionbee",
        "com.exafunction.windsurf", "com.quora.poe.electron",

        "com.sequelpro.*", "com.sequel-ace.*", "com.tinyapp.*", "com.dbeaver.*",
        "com.navicat.*", "com.mongodb.compass", "com.redis.redisinsight", "com.pgadmin.pgadmin4",
        "com.eggerapps.sequel-pro", "com.valentina-db.valentina-studio", "com.dbvis.dbvisualizer",

        "com.postmanlabs.mac", "com.getpostman.*", "com.konghq.insomnia", "com.insomnia.*",
        "com.charlesproxy.*", "com.proxyman.*", "com.getpaw.*", "com.luckymarmot.paw",
        "com.telerik.fiddler", "com.usebruno.app",

        "com.clash.*", "clashx*", "clash-*", "*-clash", "clash.*", "clash_*",
        "*clash-verge*", "clashverge*", "com.nssurge.*", "*surge*", "mihomo*",
        "*openvpn*", "net.openvpn.*", "*shadowsocksx-ng*", "com.qiuyuzhou.*", "*v2ray*",
        "*v2box*", "*nekoray*", "*sing-box*", "*onebox*", "*hiddify*", "*loon*",
        "*quantumult*", "*tailscale*", "io.tailscale.*", "*zerotier*", "com.zerotier.*",
        "*1dot1dot1dot1*", "*cloudflare*warp*", "org.amnezia.*", "*amnezia*",
        "com.wireguard.*", "*wireguard*", "*nordvpn*", "*expressvpn*", "*protonvpn*",
        "*surfshark*", "*windscribe*", "*mullvad*", "*privateinternetaccess*",

        "*aerial.saver*", "com.johncoates.aerial*", "*fliqlo*", "com.github.githubdesktop",
        "com.sublimemerge", "com.torusknot.sourcetreenotmas", "com.git-tower.tower*",
        "com.gitfox.gitfox", "com.github.gitify", "com.fork.fork", "com.axosoft.gitkraken",

        "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
        "com.hyper.hyper", "com.mizage.divvy", "com.fig.fig", "dev.warp.warp-stable",
        "com.termius-dmg", "com.docker.*", "dev.orbstack.*", "com.orbstack.orbstack",
        "dev.kdrag0n.macvirt", "com.getutm.utm", "com.utmapp.utm", "com.vmware.fusion",
        "com.parallels.desktop.*", "org.virtualbox.app.virtualbox", "com.vagrant.*",

        "com.bjango.istatmenus*", "eu.exelban.stats", "com.monitorcontrol.*",
        "com.bresink.system-toolkit.*", "com.mediaatelier.menumeters", "com.activity-indicator.app",
        "net.cindori.sensei", "com.macitbetter.*", "com.hegenberg.*", "com.manytricks.*",
        "com.divisiblebyzero.*", "com.koingdev.*", "com.if.amphetamine", "com.lwouis.alt-tab-macos",
        "net.matthewpalmer.vanilla", "com.lightheadsw.caffeine", "com.contextual.contexts",
        "com.amethyst.amethyst", "com.knollsoft.rectangle", "com.knollsoft.hookshot",
        "com.surteesstudios.bartender", "com.gaosun.eul", "com.pointum.hazeover",

        "com.runningwithcrayons.alfred", "com.raycast.*", "com.raycast-x.*",
        "com.blacktree.quicksilver", "com.stairways.keyboardmaestro.*", "com.happenapps.quitter",
        "com.pilotmoon.scroll-reverser", "com.bear-writer.*", "com.typora.*", "com.ulyssesapp.*",
        "com.literatureandlatte.*", "com.dayoneapp.*", "notion.id", "md.obsidian",
        "com.logseq.logseq", "com.evernote.evernote", "com.onenote.mac",
        "com.omnigroup.omnioutliner*", "net.shinyfrog.bear", "com.goodnotes.goodnotes",
        "com.marginnote.marginnote*", "com.roamresearch.*", "com.reflect.reflectapp", "com.inkdrop.*",

        "com.adobe.*", "com.avid.mediacomposer*", "com.bohemiancoding.*", "com.figma.*",
        "com.framerx.*", "com.zeplin.*", "com.invisionapp.*", "com.principle.*",
        "com.pixelmatorteam.*", "com.affinitydesigner.*", "com.affinityphoto.*",
        "com.affinitypublisher.*", "com.linearity.curve", "com.canva.canvadesktop",
        "com.maxon.cinema4d", "com.autodesk.*", "com.sketchup.*", "com.native-instruments.*",
        "com.fabfilter.*", "com.paceap.*", "com.izotope.*", "izotope",
        "com.lasersoft-imaging.*", "app.cotypist.cotypist",

        "com.tencent.xinwechat", "com.tencent.qq", "com.alibaba.*", "us.zoom.xos",
        "us.zoom.updater*", "com.microsoft.teams*", "com.slack.slack", "com.hnc.discord",
        "app.legcord.legcord", "org.telegram.desktop", "ru.keepcoder.telegram",
        "net.whatsapp.whatsapp", "com.skype.skype", "com.cisco.webexmeetings",
        "com.ringcentral.ringcentral", "com.readdle.smartemail-mac", "com.airmail.*",
        "com.postbox-inc.postbox", "com.tinyspeck.slackmacgap",

        "com.omnigroup.omnifocus*", "com.culturedcode.*", "com.todoist.*", "com.any.do.*",
        "com.ticktick.*", "com.microsoft.to-do", "com.trello.trello", "com.asana.nativeapp",
        "com.clickup.*", "com.monday.desktop", "com.airtable.airtable", "com.notion.id",
        "com.linear.linear", "com.panic.transmit*", "com.binarynights.forklift*",
        "com.noodlesoft.hazel", "com.cyberduck.cyberduck", "io.filezilla.filezilla",
        "com.synology.*",

        "com.dropbox.*", "com.getdropbox.*", "*dropbox*", "ws.agile.*", "com.backblaze.*",
        "*backblaze*", "com.box.desktop*", "*box.desktop*", "com.microsoft.onedrive*",
        "com.microsoft.syncreporter", "*onedrive*", "com.google.googledrive",
        "com.google.keystone*", "*googledrive*", "com.amazon.drive", "com.displaylink.*",
        "com.fujitsu.pfu.scansnap*", "com.citrix.*", "org.xquartz.*", "com.digidna.imazing*",
        "com.shirtpocket.*", "homebrew.mxcl.*", "org.chromium.chromoting*",
        "com.google.chrome_remote_desktop*", "com.teamviewer.*", "com.realvnc.*",
        "com.logmein.*", "com.anydesk.*",

        "com.cleanshot.*", "com.xnipapp.xnip", "com.reincubate.camo",
        "com.tunabellysoftware.screenfloat", "net.telestream.screenflow*", "com.techsmith.snagit*",
        "com.techsmith.camtasia*", "com.obsidianapp.screenrecorder", "com.kap.kap",
        "com.getkap.*", "com.linebreak.cloudapp", "com.droplr.droplr-mac",
        "com.spotify.client", "com.blackmagic-design.*", "com.colliderli.iina", "org.videolan.vlc",
        "io.mpv", "tv.plex.player.desktop", "com.netease.163music", "firefox", "org.mozilla.*",

        "com.crowdstrike.*", "com.kolide.*", "com.sas.*", "com.mathworks.*", "com.ibm.spss.*",
        "com.wolfram.*", "com.stata.*", "org.rstudio.*", "com.tableausoftware.*",
        "com.paddle.paddle*", "com.quicken.*", "com.setapp.desktopclient", "com.devmate.*",
        "org.sparkle-project.sparkle*"
    ]
}
