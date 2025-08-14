//
//  ProviderIcons.swift
//  CodeAgentsMobile
//
//  Purpose: Custom icons for cloud providers
//

import SwiftUI

/// Hetzner server icon (exact SVG path recreation)
struct HetznerServerIcon: View {
    var size: CGFloat = 24
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = min(width, height) / 24.0
            
            ZStack {
                // Top server unit with rounded corners
                Path { path in
                    let rect = CGRect(
                        x: 3 * scale,
                        y: 4 * scale,
                        width: 18 * scale,
                        height: 8 * scale
                    )
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 3 * scale, height: 3 * scale))
                }
                .stroke(lineWidth: 2 * scale)
                
                // Bottom server unit with rounded corners
                Path { path in
                    let rect = CGRect(
                        x: 3 * scale,
                        y: 12 * scale,
                        width: 18 * scale,
                        height: 8 * scale
                    )
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 3 * scale, height: 3 * scale))
                }
                .stroke(lineWidth: 2 * scale)
                
                // Top server LED indicator (small circle)
                Circle()
                    .fill()
                    .frame(width: 2 * scale, height: 2 * scale)
                    .position(x: 7 * scale, y: 8 * scale)
                
                // Bottom server LED indicator (small circle)
                Circle()
                    .fill()
                    .frame(width: 2 * scale, height: 2 * scale)
                    .position(x: 7 * scale, y: 16 * scale)
            }
        }
        .frame(width: size, height: size)
    }
}

/// DigitalOcean droplet icon (exact SVG path recreation)
struct DigitalOceanDropletIcon: View {
    var size: CGFloat = 24
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = min(width, height) / 24.0
            
            Path { path in
                // Exact SVG path data parsing:
                // M7.502 19.423 - Move to (7.502, 19.423)
                // c2.602 2.105 6.395 2.105 8.996 0 - Cubic curve relative
                // c2.602 -2.105 3.262 -5.708 1.566 -8.546 - Cubic curve relative
                // l-4.89 -7.26 - Line relative
                // c-.42 -.625 -1.287 -.803 -1.936 -.397 - Cubic curve relative
                // a1.376 1.376 0 0 0 -.41 .397 - Arc (simplified as curve)
                // l-4.893 7.26 - Line relative
                // c-1.695 2.838 -1.035 6.441 1.567 8.546 - Cubic curve relative
                // z - Close path
                
                // Starting point (bottom left of droplet)
                let startX = 7.502 * scale
                let startY = 19.423 * scale
                path.move(to: CGPoint(x: startX, y: startY))
                
                // First cubic curve - bottom curve of droplet
                var currentX = startX
                var currentY = startY
                path.addCurve(
                    to: CGPoint(x: currentX + 8.996 * scale, y: currentY + 0 * scale),
                    control1: CGPoint(x: currentX + 2.602 * scale, y: currentY + 2.105 * scale),
                    control2: CGPoint(x: currentX + 6.395 * scale, y: currentY + 2.105 * scale)
                )
                currentX += 8.996 * scale
                currentY += 0 * scale
                
                // Second cubic curve - right side up
                path.addCurve(
                    to: CGPoint(x: currentX + 1.566 * scale, y: currentY - 8.546 * scale),
                    control1: CGPoint(x: currentX + 2.602 * scale, y: currentY - 2.105 * scale),
                    control2: CGPoint(x: currentX + 3.262 * scale, y: currentY - 5.708 * scale)
                )
                currentX += 1.566 * scale
                currentY -= 8.546 * scale
                
                // Line to top right
                currentX -= 4.89 * scale
                currentY -= 7.26 * scale
                path.addLine(to: CGPoint(x: currentX, y: currentY))
                
                // Cubic curve at top
                path.addCurve(
                    to: CGPoint(x: currentX - 1.936 * scale, y: currentY - 0.397 * scale),
                    control1: CGPoint(x: currentX - 0.42 * scale, y: currentY - 0.625 * scale),
                    control2: CGPoint(x: currentX - 1.287 * scale, y: currentY - 0.803 * scale)
                )
                currentX -= 1.936 * scale
                currentY -= 0.397 * scale
                
                // Small arc (approximated as line for simplicity)
                currentX -= 0.41 * scale
                currentY += 0.397 * scale
                path.addLine(to: CGPoint(x: currentX, y: currentY))
                
                // Line down left side
                currentX -= 4.893 * scale
                currentY += 7.26 * scale
                path.addLine(to: CGPoint(x: currentX, y: currentY))
                
                // Final cubic curve back to start
                path.addCurve(
                    to: CGPoint(x: startX, y: startY),
                    control1: CGPoint(x: currentX - 1.695 * scale, y: currentY + 2.838 * scale),
                    control2: CGPoint(x: currentX - 1.035 * scale, y: currentY + 6.441 * scale)
                )
                
                path.closeSubpath()
            }
            .stroke(lineWidth: 2 * scale)
        }
        .frame(width: size, height: size)
    }
}

/// Helper to get the appropriate icon for a provider
struct ProviderIcon: View {
    let providerType: String
    var size: CGFloat = 24
    var color: Color = .primary
    
    var body: some View {
        Group {
            switch providerType.lowercased() {
            case "hetzner":
                HetznerServerIcon(size: size)
                    .foregroundColor(color)
            case "digitalocean", "do":
                DigitalOceanDropletIcon(size: size)
                    .foregroundColor(color)
            default:
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.7))
                    .foregroundColor(color)
            }
        }
    }
}

/// Provider logo with background
struct ProviderLogo: View {
    let providerType: String
    var size: CGFloat = 40
    
    private var backgroundColor: Color {
        switch providerType.lowercased() {
        case "hetzner":
            return Color.red.opacity(0.1)
        case "digitalocean", "do":
            return Color.blue.opacity(0.1)
        default:
            return Color.gray.opacity(0.1)
        }
    }
    
    private var foregroundColor: Color {
        switch providerType.lowercased() {
        case "hetzner":
            return .red
        case "digitalocean", "do":
            return .blue
        default:
            return .gray
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)
            
            ProviderIcon(providerType: providerType, size: size * 0.6, color: foregroundColor)
        }
    }
}

// MARK: - Previews

struct ProviderIcons_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            HStack(spacing: 40) {
                VStack {
                    Text("Hetzner")
                        .font(.caption)
                    HetznerServerIcon(size: 40)
                }
                
                VStack {
                    Text("DigitalOcean")
                        .font(.caption)
                    DigitalOceanDropletIcon(size: 40)
                }
            }
            
            Divider()
            
            HStack(spacing: 40) {
                VStack {
                    Text("Hetzner Logo")
                        .font(.caption)
                    ProviderLogo(providerType: "hetzner", size: 60)
                }
                
                VStack {
                    Text("DO Logo")
                        .font(.caption)
                    ProviderLogo(providerType: "digitalocean", size: 60)
                }
            }
            
            Divider()
            
            HStack(spacing: 20) {
                ProviderIcon(providerType: "hetzner", size: 24, color: .red)
                ProviderIcon(providerType: "digitalocean", size: 24, color: .blue)
                ProviderIcon(providerType: "other", size: 24, color: .gray)
            }
        }
        .padding()
    }
}