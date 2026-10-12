// StatusLabel.swift - A status message with a coloured icon.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import SwiftUI

/// A status message whose icon carries the colour. The text keeps the normal
/// label colour, because green or orange text on a light background is hard
/// to read.
struct StatusLabel: View {
  let text: String
  let systemImage: String
  let color: Color

  init(_ text: String, systemImage: String, color: Color) {
    self.text = text
    self.systemImage = systemImage
    self.color = color
  }

  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(color)
    }
  }
}
