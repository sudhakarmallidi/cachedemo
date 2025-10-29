# Contact App

A simple iOS app built with SwiftUI that allows users to retrieve and search through their device contacts.

## Features

- **Contact Retrieval**: Tap the "Retrieve Contacts" button to fetch contacts from your device
- **Search Functionality**: Search through contacts by name, phone number, or country
- **Contact Information**: Each contact displays:
  - Full name
  - Mobile phone number
  - Country (detected from phone number)
- **Modern UI**: Clean, intuitive interface with SwiftUI

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.0+

## Setup Instructions

1. Open the project in Xcode
2. Build and run the project on a device or simulator
3. When prompted, grant permission to access contacts
4. Tap "Retrieve Contacts" to load your contacts
5. Use the search bar to filter contacts

## Permissions

The app requires access to your device's contacts. When you first tap "Retrieve Contacts", iOS will prompt you to grant permission. You can also manage this permission in Settings > Privacy & Security > Contacts.

## Project Structure

- `ContactAppApp.swift` - Main app entry point
- `ContentView.swift` - Main view with contact list and search functionality
- `Contact.swift` - Contact data model
- `ContactManager.swift` - Handles contact retrieval and permissions
- `Info.plist` - App configuration and permissions

## How It Works

1. The app uses the `Contacts` framework to access device contacts
2. Contact information is parsed and stored in a custom `Contact` model
3. Country detection is performed based on phone number prefixes
4. The UI provides real-time search filtering across all contact fields
5. All operations are performed asynchronously to maintain smooth UI performance

## Country Detection

The app includes basic country detection based on international phone number prefixes. It supports major countries including:
- United States (+1)
- United Kingdom (+44)
- Germany (+49)
- France (+33)
- India (+91)
- China (+86)
- And many more...

## Customization

You can easily customize the app by:
- Modifying the contact display format in `ContactRow`
- Adding more country detection patterns in `ContactManager`
- Changing the UI colors and styling in `ContentView`
- Adding additional contact fields (email, address, etc.)

## Privacy

This app only reads contact information and does not store or transmit any data. All contact processing happens locally on your device.
# cachedemo

