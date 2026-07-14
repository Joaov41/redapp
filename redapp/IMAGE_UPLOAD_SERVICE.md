# Image Upload Service Documentation

## Overview

This app uses **Catbox.moe** for image uploads when creating Reddit posts. This document explains how it works and why it was chosen.

## What is Catbox.moe?

Catbox.moe is a free, anonymous file hosting service that has been operating reliably for years. It specializes in image hosting and is widely used across the internet.

## Key Features

### No API Key Required
- **100% Anonymous**: No registration, no API key, no authentication needed
- **Zero Configuration**: Works immediately out of the box
- **No User Setup**: Your app users don't need to do anything

### How It Works
The app uploads images directly to Catbox's public endpoint:
```
https://catbox.moe/user/api.php
```

Each upload is:
- Independent and anonymous
- Not tied to any account or API key
- Processed immediately with a direct URL returned

### Benefits for Your App

1. **No Credentials Management**: Unlike Imgur or Reddit's native upload, users don't need to obtain or manage API credentials
2. **Immediate Functionality**: Image upload works the moment users install your app
3. **No Rate Limits**: No API key means no rate limit tied to a specific key
4. **Reliable Service**: Catbox has been operating for years with good uptime
5. **Reddit Compatible**: Reddit accepts and displays Catbox URLs properly

## Technical Implementation

The upload process is simple:
1. User selects an image in your app
2. App sends the image to Catbox via HTTP POST
3. Catbox returns a direct URL (e.g., `https://files.catbox.moe/abc123.jpg`)
4. App submits this URL to Reddit as a link post
5. Reddit displays the image preview automatically

## Privacy and Terms

- Images uploaded to Catbox are publicly accessible via their URL
- Catbox states they don't monitor or view uploaded content
- They remove illegal content when reported
- No personal information is collected during upload

## Why Not Other Services?

- **Imgur**: Requires API registration that is currently broken/unavailable
- **Reddit Native Upload**: Complex implementation, was causing 404 errors
- **Other Services**: Most require API keys or authentication

## For App Users

Users should be aware:
- Images uploaded through the app will be hosted on Catbox.moe
- These images are publicly accessible if someone has the URL
- There's no way to delete images after upload (since it's anonymous)
- The service is free and requires no setup

## Reliability

Catbox.moe has been operating since 2016 and is widely used. However, as with any free service:
- There's no guarantee of permanent availability
- No SLA or uptime guarantees
- The service could change or shut down in the future

For a commercial app, you may want to consider:
- Implementing multiple upload services as fallbacks
- Allowing users to choose their preferred image host
- Or implementing a paid image hosting solution

## Summary

Catbox.moe provides a simple, working solution for image uploads that requires zero configuration from you or your users. It's perfect for getting your app working immediately, though you may want to revisit the image hosting strategy for a long-term commercial solution.