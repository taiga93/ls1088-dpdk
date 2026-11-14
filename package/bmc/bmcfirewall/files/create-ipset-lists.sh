#!/bin/sh

set -eu

command -v ipset >/dev/null 2>&1 || {
    echo 'Error: ipset command is not installed' >&2
    exit 1
}

# 4chan (4chan)
ipset create 'agh_000_4chan_4' hash:ip family inet -exist
ipset create 'agh_000_4chan_6' hash:ip family inet6 -exist

# 500px (500px)
ipset create 'agh_001_500px_4' hash:ip family inet -exist
ipset create 'agh_001_500px_6' hash:ip family inet6 -exist

# 9GAG (9gag)
ipset create 'agh_002_9gag_4' hash:ip family inet -exist
ipset create 'agh_002_9gag_6' hash:ip family inet6 -exist

# Activision Blizzard (activision_blizzard)
ipset create 'agh_003_activision_blizzar_4' hash:ip family inet -exist
ipset create 'agh_003_activision_blizzar_6' hash:ip family inet6 -exist

# AliExpress (aliexpress)
ipset create 'agh_004_aliexpress_4' hash:ip family inet -exist
ipset create 'agh_004_aliexpress_6' hash:ip family inet6 -exist

# Amazon (amazon)
ipset create 'agh_005_amazon_4' hash:ip family inet -exist
ipset create 'agh_005_amazon_6' hash:ip family inet6 -exist

# Amazon Streaming (amazon_streaming)
ipset create 'agh_006_amazon_streaming_4' hash:ip family inet -exist
ipset create 'agh_006_amazon_streaming_6' hash:ip family inet6 -exist

# Amino (amino)
ipset create 'agh_007_amino_4' hash:ip family inet -exist
ipset create 'agh_007_amino_6' hash:ip family inet6 -exist

# Apple Streaming (apple_streaming)
ipset create 'agh_008_apple_streaming_4' hash:ip family inet -exist
ipset create 'agh_008_apple_streaming_6' hash:ip family inet6 -exist

# Battle.net (battle_net)
ipset create 'agh_009_battle_net_4' hash:ip family inet -exist
ipset create 'agh_009_battle_net_6' hash:ip family inet6 -exist

# Betano (betano)
ipset create 'agh_010_betano_4' hash:ip family inet -exist
ipset create 'agh_010_betano_6' hash:ip family inet6 -exist

# Betfair (betfair)
ipset create 'agh_011_betfair_4' hash:ip family inet -exist
ipset create 'agh_011_betfair_6' hash:ip family inet6 -exist

# Betway (betway)
ipset create 'agh_012_betway_4' hash:ip family inet -exist
ipset create 'agh_012_betway_6' hash:ip family inet6 -exist

# Bigo Live (bigo_live)
ipset create 'agh_013_bigo_live_4' hash:ip family inet -exist
ipset create 'agh_013_bigo_live_6' hash:ip family inet6 -exist

# Bilibili (bilibili)
ipset create 'agh_014_bilibili_4' hash:ip family inet -exist
ipset create 'agh_014_bilibili_6' hash:ip family inet6 -exist

# Blaze (blaze)
ipset create 'agh_015_blaze_4' hash:ip family inet -exist
ipset create 'agh_015_blaze_6' hash:ip family inet6 -exist

# Blizzard Entertainment (blizzard_entertainment)
ipset create 'agh_016_blizzard_entertain_4' hash:ip family inet -exist
ipset create 'agh_016_blizzard_entertain_6' hash:ip family inet6 -exist

# Bluesky (bluesky)
ipset create 'agh_017_bluesky_4' hash:ip family inet -exist
ipset create 'agh_017_bluesky_6' hash:ip family inet6 -exist

# Box (box)
ipset create 'agh_018_box_4' hash:ip family inet -exist
ipset create 'agh_018_box_6' hash:ip family inet6 -exist

# Canais Globo (canais_globo)
ipset create 'agh_019_canais_globo_4' hash:ip family inet -exist
ipset create 'agh_019_canais_globo_6' hash:ip family inet6 -exist

# ChatGPT (chatgpt)
ipset create 'agh_020_chatgpt_4' hash:ip family inet -exist
ipset create 'agh_020_chatgpt_6' hash:ip family inet6 -exist

# Claro (claro)
ipset create 'agh_021_claro_4' hash:ip family inet -exist
ipset create 'agh_021_claro_6' hash:ip family inet6 -exist

# Claude (claude)
ipset create 'agh_022_claude_4' hash:ip family inet -exist
ipset create 'agh_022_claude_6' hash:ip family inet6 -exist

# Cloudflare (cloudflare)
ipset create 'agh_023_cloudflare_4' hash:ip family inet -exist
ipset create 'agh_023_cloudflare_6' hash:ip family inet6 -exist

# Clubhouse (clubhouse)
ipset create 'agh_024_clubhouse_4' hash:ip family inet -exist
ipset create 'agh_024_clubhouse_6' hash:ip family inet6 -exist

# CoolApk (coolapk)
ipset create 'agh_025_coolapk_4' hash:ip family inet -exist
ipset create 'agh_025_coolapk_6' hash:ip family inet6 -exist

# Copilot (copilot)
ipset create 'agh_026_copilot_4' hash:ip family inet -exist
ipset create 'agh_026_copilot_6' hash:ip family inet6 -exist

# Crunchyroll (crunchyroll)
ipset create 'agh_027_crunchyroll_4' hash:ip family inet -exist
ipset create 'agh_027_crunchyroll_6' hash:ip family inet6 -exist

# Dailymotion (dailymotion)
ipset create 'agh_028_dailymotion_4' hash:ip family inet -exist
ipset create 'agh_028_dailymotion_6' hash:ip family inet6 -exist

# DeepSeek (deepseek)
ipset create 'agh_029_deepseek_4' hash:ip family inet -exist
ipset create 'agh_029_deepseek_6' hash:ip family inet6 -exist

# Deezer (deezer)
ipset create 'agh_030_deezer_4' hash:ip family inet -exist
ipset create 'agh_030_deezer_6' hash:ip family inet6 -exist

# DirecTV Go (directvgo)
ipset create 'agh_031_directvgo_4' hash:ip family inet -exist
ipset create 'agh_031_directvgo_6' hash:ip family inet6 -exist

# Discord (discord)
ipset create 'agh_032_discord_4' hash:ip family inet -exist
ipset create 'agh_032_discord_6' hash:ip family inet6 -exist

# Discovery+ (discoveryplus)
ipset create 'agh_033_discoveryplus_4' hash:ip family inet -exist
ipset create 'agh_033_discoveryplus_6' hash:ip family inet6 -exist

# Disney+ (disneyplus)
ipset create 'agh_034_disneyplus_4' hash:ip family inet -exist
ipset create 'agh_034_disneyplus_6' hash:ip family inet6 -exist

# Douban (douban)
ipset create 'agh_035_douban_4' hash:ip family inet -exist
ipset create 'agh_035_douban_6' hash:ip family inet6 -exist

# Dropbox (dropbox)
ipset create 'agh_036_dropbox_4' hash:ip family inet -exist
ipset create 'agh_036_dropbox_6' hash:ip family inet6 -exist

# eBay (ebay)
ipset create 'agh_037_ebay_4' hash:ip family inet -exist
ipset create 'agh_037_ebay_6' hash:ip family inet6 -exist

# Electronic Arts (electronic_arts)
ipset create 'agh_038_electronic_arts_4' hash:ip family inet -exist
ipset create 'agh_038_electronic_arts_6' hash:ip family inet6 -exist

# Epic Games (epic_games)
ipset create 'agh_039_epic_games_4' hash:ip family inet -exist
ipset create 'agh_039_epic_games_6' hash:ip family inet6 -exist

# ESPN (espn)
ipset create 'agh_040_espn_4' hash:ip family inet -exist
ipset create 'agh_040_espn_6' hash:ip family inet6 -exist

# Facebook (facebook)
ipset create 'agh_041_facebook_4' hash:ip family inet -exist
ipset create 'agh_041_facebook_6' hash:ip family inet6 -exist

# FIFA (fifa)
ipset create 'agh_042_fifa_4' hash:ip family inet -exist
ipset create 'agh_042_fifa_6' hash:ip family inet6 -exist

# Flickr (flickr)
ipset create 'agh_043_flickr_4' hash:ip family inet -exist
ipset create 'agh_043_flickr_6' hash:ip family inet6 -exist

# Gemini (gemini)
ipset create 'agh_044_gemini_4' hash:ip family inet -exist
ipset create 'agh_044_gemini_6' hash:ip family inet6 -exist

# Globoplay (globoplay)
ipset create 'agh_045_globoplay_4' hash:ip family inet -exist
ipset create 'agh_045_globoplay_6' hash:ip family inet6 -exist

# GOG (gog)
ipset create 'agh_046_gog_4' hash:ip family inet -exist
ipset create 'agh_046_gog_6' hash:ip family inet6 -exist

# Grok (grok)
ipset create 'agh_047_grok_4' hash:ip family inet -exist
ipset create 'agh_047_grok_6' hash:ip family inet6 -exist

# HBO Max (hbomax)
ipset create 'agh_048_hbomax_4' hash:ip family inet -exist
ipset create 'agh_048_hbomax_6' hash:ip family inet6 -exist

# Hulu (hulu)
ipset create 'agh_049_hulu_4' hash:ip family inet -exist
ipset create 'agh_049_hulu_6' hash:ip family inet6 -exist

# iCloud Private Relay (icloud_private_relay)
ipset create 'agh_050_icloud_private_rel_4' hash:ip family inet -exist
ipset create 'agh_050_icloud_private_rel_6' hash:ip family inet6 -exist

# iHeartRadio (iheartradio)
ipset create 'agh_051_iheartradio_4' hash:ip family inet -exist
ipset create 'agh_051_iheartradio_6' hash:ip family inet6 -exist

# Imgur (imgur)
ipset create 'agh_052_imgur_4' hash:ip family inet -exist
ipset create 'agh_052_imgur_6' hash:ip family inet6 -exist

# Instagram (instagram)
ipset create 'agh_053_instagram_4' hash:ip family inet -exist
ipset create 'agh_053_instagram_6' hash:ip family inet6 -exist

# IO Interactive (io_interactive)
ipset create 'agh_054_io_interactive_4' hash:ip family inet -exist
ipset create 'agh_054_io_interactive_6' hash:ip family inet6 -exist

# iQIYI (iqiyi)
ipset create 'agh_055_iqiyi_4' hash:ip family inet -exist
ipset create 'agh_055_iqiyi_6' hash:ip family inet6 -exist

# KakaoTalk (kakaotalk)
ipset create 'agh_056_kakaotalk_4' hash:ip family inet -exist
ipset create 'agh_056_kakaotalk_6' hash:ip family inet6 -exist

# Kik (kik)
ipset create 'agh_057_kik_4' hash:ip family inet -exist
ipset create 'agh_057_kik_6' hash:ip family inet6 -exist

# KOOK (kook)
ipset create 'agh_058_kook_4' hash:ip family inet -exist
ipset create 'agh_058_kook_6' hash:ip family inet6 -exist

# Lazada (lazada)
ipset create 'agh_059_lazada_4' hash:ip family inet -exist
ipset create 'agh_059_lazada_6' hash:ip family inet6 -exist

# League of Legends (leagueoflegends)
ipset create 'agh_060_leagueoflegends_4' hash:ip family inet -exist
ipset create 'agh_060_leagueoflegends_6' hash:ip family inet6 -exist

# LINE (line)
ipset create 'agh_061_line_4' hash:ip family inet -exist
ipset create 'agh_061_line_6' hash:ip family inet6 -exist

# LinkedIn (linkedin)
ipset create 'agh_062_linkedin_4' hash:ip family inet -exist
ipset create 'agh_062_linkedin_6' hash:ip family inet6 -exist

# Lionsgate+ (lionsgateplus)
ipset create 'agh_063_lionsgateplus_4' hash:ip family inet -exist
ipset create 'agh_063_lionsgateplus_6' hash:ip family inet6 -exist

# Looke (looke)
ipset create 'agh_064_looke_4' hash:ip family inet -exist
ipset create 'agh_064_looke_6' hash:ip family inet6 -exist

# Mail.ru (mail_ru)
ipset create 'agh_065_mail_ru_4' hash:ip family inet -exist
ipset create 'agh_065_mail_ru_6' hash:ip family inet6 -exist

# Manus (manus)
ipset create 'agh_066_manus_4' hash:ip family inet -exist
ipset create 'agh_066_manus_6' hash:ip family inet6 -exist

# Mastodon (mastodon)
ipset create 'agh_067_mastodon_4' hash:ip family inet -exist
ipset create 'agh_067_mastodon_6' hash:ip family inet6 -exist

# MAX (max)
ipset create 'agh_068_max_4' hash:ip family inet -exist
ipset create 'agh_068_max_6' hash:ip family inet6 -exist

# Mercado Libre (mercado_libre)
ipset create 'agh_069_mercado_libre_4' hash:ip family inet -exist
ipset create 'agh_069_mercado_libre_6' hash:ip family inet6 -exist

# Meta AI (meta_ai)
ipset create 'agh_070_meta_ai_4' hash:ip family inet -exist
ipset create 'agh_070_meta_ai_6' hash:ip family inet6 -exist

# Microsoft Teams (microsoft_teams)
ipset create 'agh_071_microsoft_teams_4' hash:ip family inet -exist
ipset create 'agh_071_microsoft_teams_6' hash:ip family inet6 -exist

# Minecraft (minecraft)
ipset create 'agh_072_minecraft_4' hash:ip family inet -exist
ipset create 'agh_072_minecraft_6' hash:ip family inet6 -exist

# Nebula (nebula)
ipset create 'agh_073_nebula_4' hash:ip family inet -exist
ipset create 'agh_073_nebula_6' hash:ip family inet6 -exist

# Netflix (netflix)
ipset create 'agh_074_netflix_4' hash:ip family inet -exist
ipset create 'agh_074_netflix_6' hash:ip family inet6 -exist

# Nintendo (nintendo)
ipset create 'agh_075_nintendo_4' hash:ip family inet -exist
ipset create 'agh_075_nintendo_6' hash:ip family inet6 -exist

# Nvidia (nvidia)
ipset create 'agh_076_nvidia_4' hash:ip family inet -exist
ipset create 'agh_076_nvidia_6' hash:ip family inet6 -exist

# Odysee (odysee)
ipset create 'agh_077_odysee_4' hash:ip family inet -exist
ipset create 'agh_077_odysee_6' hash:ip family inet6 -exist

# OK.ru (ok)
ipset create 'agh_078_ok_4' hash:ip family inet -exist
ipset create 'agh_078_ok_6' hash:ip family inet6 -exist

# Olvid (olvid)
ipset create 'agh_079_olvid_4' hash:ip family inet -exist
ipset create 'agh_079_olvid_6' hash:ip family inet6 -exist

# OnlyFans (onlyfans)
ipset create 'agh_080_onlyfans_4' hash:ip family inet -exist
ipset create 'agh_080_onlyfans_6' hash:ip family inet6 -exist

# Origin (origin)
ipset create 'agh_081_origin_4' hash:ip family inet -exist
ipset create 'agh_081_origin_6' hash:ip family inet6 -exist

# Paramount Plus (paramountplus)
ipset create 'agh_082_paramountplus_4' hash:ip family inet -exist
ipset create 'agh_082_paramountplus_6' hash:ip family inet6 -exist

# Peacock TV (peacock_tv)
ipset create 'agh_083_peacock_tv_4' hash:ip family inet -exist
ipset create 'agh_083_peacock_tv_6' hash:ip family inet6 -exist

# Perplexity (perplexity)
ipset create 'agh_084_perplexity_4' hash:ip family inet -exist
ipset create 'agh_084_perplexity_6' hash:ip family inet6 -exist

# Pinterest (pinterest)
ipset create 'agh_085_pinterest_4' hash:ip family inet -exist
ipset create 'agh_085_pinterest_6' hash:ip family inet6 -exist

# PlayStation (playstation)
ipset create 'agh_086_playstation_4' hash:ip family inet -exist
ipset create 'agh_086_playstation_6' hash:ip family inet6 -exist

# Google Play Store (playstore)
ipset create 'agh_087_playstore_4' hash:ip family inet -exist
ipset create 'agh_087_playstore_6' hash:ip family inet6 -exist

# Plenty of Fish (plenty_of_fish)
ipset create 'agh_088_plenty_of_fish_4' hash:ip family inet -exist
ipset create 'agh_088_plenty_of_fish_6' hash:ip family inet6 -exist

# Plex (plex)
ipset create 'agh_089_plex_4' hash:ip family inet -exist
ipset create 'agh_089_plex_6' hash:ip family inet6 -exist

# Pluto TV (pluto_tv)
ipset create 'agh_090_pluto_tv_4' hash:ip family inet -exist
ipset create 'agh_090_pluto_tv_6' hash:ip family inet6 -exist

# Privacy (privacy)
ipset create 'agh_091_privacy_4' hash:ip family inet -exist
ipset create 'agh_091_privacy_6' hash:ip family inet6 -exist

# Proton (proton)
ipset create 'agh_092_proton_4' hash:ip family inet -exist
ipset create 'agh_092_proton_6' hash:ip family inet6 -exist

# QQ (qq)
ipset create 'agh_093_qq_4' hash:ip family inet -exist
ipset create 'agh_093_qq_6' hash:ip family inet6 -exist

# Rakuten Viki (rakuten_viki)
ipset create 'agh_094_rakuten_viki_4' hash:ip family inet -exist
ipset create 'agh_094_rakuten_viki_6' hash:ip family inet6 -exist

# Reddit (reddit)
ipset create 'agh_095_reddit_4' hash:ip family inet -exist
ipset create 'agh_095_reddit_6' hash:ip family inet6 -exist

# Riot Games (riot_games)
ipset create 'agh_096_riot_games_4' hash:ip family inet -exist
ipset create 'agh_096_riot_games_6' hash:ip family inet6 -exist

# Roblox (roblox)
ipset create 'agh_097_roblox_4' hash:ip family inet -exist
ipset create 'agh_097_roblox_6' hash:ip family inet6 -exist

# Rockstar Games (rockstar_games)
ipset create 'agh_098_rockstar_games_4' hash:ip family inet -exist
ipset create 'agh_098_rockstar_games_6' hash:ip family inet6 -exist

# Samsung TV Plus (samsung_tv_plus)
ipset create 'agh_099_samsung_tv_plus_4' hash:ip family inet -exist
ipset create 'agh_099_samsung_tv_plus_6' hash:ip family inet6 -exist

# Shein (shein)
ipset create 'agh_100_shein_4' hash:ip family inet -exist
ipset create 'agh_100_shein_6' hash:ip family inet6 -exist

# Shopee (shopee)
ipset create 'agh_101_shopee_4' hash:ip family inet -exist
ipset create 'agh_101_shopee_6' hash:ip family inet6 -exist

# Signal (signal)
ipset create 'agh_102_signal_4' hash:ip family inet -exist
ipset create 'agh_102_signal_6' hash:ip family inet6 -exist

# Skype (skype)
ipset create 'agh_103_skype_4' hash:ip family inet -exist
ipset create 'agh_103_skype_6' hash:ip family inet6 -exist

# Slack (slack)
ipset create 'agh_104_slack_4' hash:ip family inet -exist
ipset create 'agh_104_slack_6' hash:ip family inet6 -exist

# Snapchat (snapchat)
ipset create 'agh_105_snapchat_4' hash:ip family inet -exist
ipset create 'agh_105_snapchat_6' hash:ip family inet6 -exist

# SoundCloud (soundcloud)
ipset create 'agh_106_soundcloud_4' hash:ip family inet -exist
ipset create 'agh_106_soundcloud_6' hash:ip family inet6 -exist

# Spotify (spotify)
ipset create 'agh_107_spotify_4' hash:ip family inet -exist
ipset create 'agh_107_spotify_6' hash:ip family inet6 -exist

# Spotify Video (spotify_video)
ipset create 'agh_108_spotify_video_4' hash:ip family inet -exist
ipset create 'agh_108_spotify_video_6' hash:ip family inet6 -exist

# Steam (steam)
ipset create 'agh_109_steam_4' hash:ip family inet -exist
ipset create 'agh_109_steam_6' hash:ip family inet6 -exist

# Telegram (Web) (telegram)
ipset create 'agh_110_telegram_4' hash:ip family inet -exist
ipset create 'agh_110_telegram_6' hash:ip family inet6 -exist

# Temu (temu)
ipset create 'agh_111_temu_4' hash:ip family inet -exist
ipset create 'agh_111_temu_6' hash:ip family inet6 -exist

# Tidal (tidal)
ipset create 'agh_112_tidal_4' hash:ip family inet -exist
ipset create 'agh_112_tidal_6' hash:ip family inet6 -exist

# TikTok (tiktok)
ipset create 'agh_113_tiktok_4' hash:ip family inet -exist
ipset create 'agh_113_tiktok_6' hash:ip family inet6 -exist

# Tinder (tinder)
ipset create 'agh_114_tinder_4' hash:ip family inet -exist
ipset create 'agh_114_tinder_6' hash:ip family inet6 -exist

# Tumblr (tumblr)
ipset create 'agh_115_tumblr_4' hash:ip family inet -exist
ipset create 'agh_115_tumblr_6' hash:ip family inet6 -exist

# Twitch (twitch)
ipset create 'agh_116_twitch_4' hash:ip family inet -exist
ipset create 'agh_116_twitch_6' hash:ip family inet6 -exist

# X (formerly Twitter) (twitter)
ipset create 'agh_117_twitter_4' hash:ip family inet -exist
ipset create 'agh_117_twitter_6' hash:ip family inet6 -exist

# Ubisoft (ubisoft)
ipset create 'agh_118_ubisoft_4' hash:ip family inet -exist
ipset create 'agh_118_ubisoft_6' hash:ip family inet6 -exist

# Valorant (valorant)
ipset create 'agh_119_valorant_4' hash:ip family inet -exist
ipset create 'agh_119_valorant_6' hash:ip family inet6 -exist

# Viber (viber)
ipset create 'agh_120_viber_4' hash:ip family inet -exist
ipset create 'agh_120_viber_6' hash:ip family inet6 -exist

# Vimeo (vimeo)
ipset create 'agh_121_vimeo_4' hash:ip family inet -exist
ipset create 'agh_121_vimeo_6' hash:ip family inet6 -exist

# Vivo Play (vivo_play)
ipset create 'agh_122_vivo_play_4' hash:ip family inet -exist
ipset create 'agh_122_vivo_play_6' hash:ip family inet6 -exist

# VK.com (vk)
ipset create 'agh_123_vk_4' hash:ip family inet -exist
ipset create 'agh_123_vk_6' hash:ip family inet6 -exist

# Voot (voot)
ipset create 'agh_124_voot_4' hash:ip family inet -exist
ipset create 'agh_124_voot_6' hash:ip family inet6 -exist

# Wargaming (wargaming)
ipset create 'agh_125_wargaming_4' hash:ip family inet -exist
ipset create 'agh_125_wargaming_6' hash:ip family inet6 -exist

# Warner Bros. Games (warnerbrosgames)
ipset create 'agh_126_warnerbrosgames_4' hash:ip family inet -exist
ipset create 'agh_126_warnerbrosgames_6' hash:ip family inet6 -exist

# WeChat (wechat)
ipset create 'agh_127_wechat_4' hash:ip family inet -exist
ipset create 'agh_127_wechat_6' hash:ip family inet6 -exist

# Weibo (weibo)
ipset create 'agh_128_weibo_4' hash:ip family inet -exist
ipset create 'agh_128_weibo_6' hash:ip family inet6 -exist

# WhatsApp (whatsapp)
ipset create 'agh_129_whatsapp_4' hash:ip family inet -exist
ipset create 'agh_129_whatsapp_6' hash:ip family inet6 -exist

# Wizz (wizz)
ipset create 'agh_130_wizz_4' hash:ip family inet -exist
ipset create 'agh_130_wizz_6' hash:ip family inet6 -exist

# Xbox Live (xboxlive)
ipset create 'agh_131_xboxlive_4' hash:ip family inet -exist
ipset create 'agh_131_xboxlive_6' hash:ip family inet6 -exist

# Xiaohongshu (xiaohongshu)
ipset create 'agh_132_xiaohongshu_4' hash:ip family inet -exist
ipset create 'agh_132_xiaohongshu_6' hash:ip family inet6 -exist

# YouTube (youtube)
ipset create 'agh_133_youtube_4' hash:ip family inet -exist
ipset create 'agh_133_youtube_6' hash:ip family inet6 -exist

# YY (yy)
ipset create 'agh_134_yy_4' hash:ip family inet -exist
ipset create 'agh_134_yy_6' hash:ip family inet6 -exist

# Zhihu (zhihu)
ipset create 'agh_135_zhihu_4' hash:ip family inet -exist
ipset create 'agh_135_zhihu_6' hash:ip family inet6 -exist

