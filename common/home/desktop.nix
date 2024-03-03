{
  config,
  pkgs,
  ...
}: {
  # Basic/partial home manager config. This only configures a few things that will only ever be used on nixos hosts. Main dotfile repo is more generic and should contain anything that may be used by work/macos hosts.
  # Right now just configures: hyprland, waybar

  home.stateVersion = "23.11";

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      "$mod" = "SUPER";
      "$fuckMacOSMod" = "CTRL"; # Fucking MacOS, stealing certain key bindings when accessing over VNC. Temporary workaround until something better is figured out.
      # See https://wiki.hyprland.org/Configuring/Monitors/
      monitor = ",1920x1080,0x0,1";
      exec-once = [
        "waypaper --backend swww --restore"
      ];
      bind = [
        # Mostly defaults, see: https://wiki.hyprland.org/Configuring/Binds/ for more
        "$mod, F, exec, firefox"
        "$mod, Return, exec, kitty"
        "$mod, C, killactive,"
        "$mod, M, exit,"
        "$mod, E, exec, dolphin"
        "$mod, V, togglefloating,"
        "$mod, D, exec, wofi --show drun"
        "$mod, R, exec, wofi --show run"
        "$mod, P, pseudo, # dwindle"
        "$mod, J, togglesplit, # dwindle"
        # Move focus with mod + hjkl
        "$mod, h, movefocus, l"
        "$mod, l, movefocus, r"
        "$mod, j, movefocus, u"
        "$mod, k, movefocus, d"
        # Switch workspaces with mod + [0-9]
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"
        "$mod, 0, workspace, 10"
        # Move active window to a workspace with mainMod + SHIFT + [0-9]
        "$fuckMacOSMod, 1, movetoworkspace, 1"
        "$fuckMacOSMod, 2, movetoworkspace, 2"
        "$fuckMacOSMod, 3, movetoworkspace, 3"
        "$fuckMacOSMod, 4, movetoworkspace, 4"
        "$fuckMacOSMod, 5, movetoworkspace, 5"
        "$fuckMacOSMod, 6, movetoworkspace, 6"
        "$fuckMacOSMod, 7, movetoworkspace, 7"
        "$fuckMacOSMod, 8, movetoworkspace, 8"
        "$fuckMacOSMod, 9, movetoworkspace, 9"
        "$fuckMacOSMod, 0, movetoworkspace, 10"
        # "$mod SHIFT, 1, movetoworkspace, 1"
        # "$mod SHIFT, 2, movetoworkspace, 1"
        # "$mod SHIFT, 3, movetoworkspace, 3"
        # "$mod SHIFT, 4, movetoworkspace, 4"
        # "$mod SHIFT, 5, movetoworkspace, 5"
        # "$mod SHIFT, 6, movetoworkspace, 6"
        # "$mod SHIFT, 7, movetoworkspace, 7"
        # "$mod SHIFT, 8, movetoworkspace, 8"
        # "$mod SHIFT, 9, movetoworkspace, 9"
        # "$mod SHIFT, 0, movetoworkspace, 10"
        # Example special workspace (scratchpad)
        "$mod, S, togglespecialworkspace, magic"
        "$mod SHIFT, S, movetoworkspace, special:magic"
        # Scroll through existing workspaces with mainMod + scroll
        "$mod, mouse_down, workspace, e+1"
        "$mod, mouse_up, workspace, e-1"
      ];
      bindm = [
        # Move/resize windows with mainMod + LMB/RMB and dragging
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
    };
    extraConfig = ''
      # Mostly default/example config
      # TODO move this to nix config above when less lazy

      # Some default env vars.
      env = XCURSOR_SIZE,24

      # Fix cursor
      env = WLR_NO_HARDWARE_CURSORS,1

      # For all categories, see https://wiki.hyprland.org/Configuring/Variables/
      input {
          kb_layout = us
          kb_variant =
          kb_model =
          kb_options =
          kb_rules =

          follow_mouse = 1

          touchpad {
              natural_scroll = no
          }

          sensitivity = 0 # -1.0 - 1.0, 0 means no modification.
          repeat_delay = 250
          repeat_rate = 30
      }

      general {
          # See https://wiki.hyprland.org/Configuring/Variables/ for more
          gaps_in = 2
          gaps_out = 2
          border_size = 1
          col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
          col.inactive_border = rgba(595959aa)

          layout = dwindle

          # Please see https://wiki.hyprland.org/Configuring/Tearing/ before you turn this on
          allow_tearing = false
      }

      decoration {
          # See https://wiki.hyprland.org/Configuring/Variables/ for more
          rounding = 5
          blur {
              enabled = true
              size = 3
              passes = 1
          }
          drop_shadow = yes
          shadow_range = 4
          shadow_render_power = 3
          col.shadow = rgba(1a1a1aee)
      }

      animations {
          enabled = yes
          # Some default animations, see https://wiki.hyprland.org/Configuring/Animations/ for more
          bezier = myBezier, 0.05, 0.9, 0.1, 1.05

          animation = windows, 1, 7, myBezier
          animation = windowsOut, 1, 7, default, popin 80%
          animation = border, 1, 10, default
          animation = borderangle, 1, 8, default
          animation = fade, 1, 7, default
          animation = workspaces, 1, 6, default
      }

      dwindle {
          # See https://wiki.hyprland.org/Configuring/Dwindle-Layout/ for more
          pseudotile = yes # master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
          preserve_split = yes # you probably want this
      }

      master {
          # See https://wiki.hyprland.org/Configuring/Master-Layout/ for more
          new_is_master = true
      }

      gestures {
          # See https://wiki.hyprland.org/Configuring/Variables/ for more
          workspace_swipe = off
      }

      misc {
          # See https://wiki.hyprland.org/Configuring/Variables/ for more
          force_default_wallpaper = 0 # Set to 0 to disable the anime mascot wallpapers
      }

      # Example per-device config
      # See https://wiki.hyprland.org/Configuring/Keywords/#executing for more
      device:epic-mouse-v1 {
          sensitivity = -0.5
      }
    '';
  };

  programs.waybar = {
    enable = true;
    # Mostly default/example config
    settings = {
      mainBar = {
        layer = "top";
        height = 10;
        spacing = 2;
        modules-left = [
          "hyprland/workspaces"
          "hyprland/mode"
          "hyprland/submap"
          "custom/media"
        ];
        modules-center = ["hyprland/window"];
        modules-right = [
          "mpd"
          "idle_inhibitor"
          "network"
          "cpu"
          "memory"
          "temperature"
          "tray"
          "clock"
        ];
        "hyprland/window" = {
          format = "{title}";
        };
        idle_inhibitor = {
          format = "{icon}";
          format-icons = {
            activated = "";
            deactivated = "";
          };
        };
        tray = {
          spacing = 10;
        };
        clock = {
          tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
          format-alt = "{:%Y-%m-%d}";
        };
        cpu = {
          format = "{usage}% ";
          tooltip = false;
        };
        memory = {
          format = "{}% ";
        };
        temperature = {
          critical-threshold = 80;
          format = "{temperatureC}°C {icon}";
          format-icons = ["" "" ""];
        };
        network = {
          format-wifi = "{essid} ({signalStrength}%) ";
          format-ethernet = "{ipaddr}/{cidr} ";
          tooltip-format = "{ifname} via {gwaddr} ";
          format-linked = "{ifname} (No IP) ";
          format-disconnected = "Disconnected ⚠";
          format-alt = "{ifname}: {ipaddr}/{cidr}";
        };
        "custom/media" = {
          format = "{icon} {}";
          return-type = "json";
          max-length = 40;
          format-icons = {
            spotify = "";
            default = "🎜";
          };
          escape = true;
          exec = "$HOME/.config/waybar/mediaplayer.py 2> /dev/null";
          # exec = "$HOME/.config/waybar/mediaplayer.py --player spotify 2> /dev/null" // Filter player based on name
        };
      };
    };
  };
}
