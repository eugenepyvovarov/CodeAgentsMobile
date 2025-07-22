# CodeAgents - Comprehensive Project Documentation

## Executive Summary

CodeAgents is a sophisticated iOS application that brings the power of Claude Code by Anthropic® to mobile devices. It provides developers with a Replit-like experience on iOS, enabling them to code on-the-go by connecting to remote development servers via SSH and interacting with Claude Code through a native SwiftUI interface. The app seamlessly integrates remote file management, AI-powered coding assistance, and terminal capabilities into a mobile-optimized experience.

## Table of Contents

1. [Technical Architecture](#technical-architecture)
2. [Core Features & Capabilities](#core-features--capabilities)
3. [Component Deep Dive](#component-deep-dive)
4. [Services Layer](#services-layer)
5. [User Interface Components](#user-interface-components)
6. [Data Models & Persistence](#data-models--persistence)
7. [Security Architecture](#security-architecture)
8. [Networking & Communication](#networking--communication)
9. [Key Algorithms & Patterns](#key-algorithms--patterns)
10. [Current Limitations & Future Roadmap](#current-limitations--future-roadmap)

## Technical Architecture

### Technology Stack
- **Language**: Swift 5.9+ with modern concurrency
- **UI Framework**: SwiftUI with @Observable macro
- **Data Persistence**: SwiftData (iOS 17+)
- **SSH Library**: SwiftNIO SSH (Apple's official implementation)
- **Authentication**: iOS Keychain Services
- **Minimum iOS Version**: iOS 17.0
- **Architecture Pattern**: MVVM with Protocol-Oriented Programming

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer (SwiftUI)                    │
├─────────────────────────────────────────────────────────────┤
│                    ViewModels (@Observable)                  │
├─────────────────────────────────────────────────────────────┤
│                       Services Layer                         │
│  ┌─────────────┬──────────────┬────────────┬─────────────┐ │
│  │ SSHService  │ ClaudeService │ FileService│ AuthService │ │
│  └─────────────┴──────────────┴────────────┴─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                    Data Layer (SwiftData)                    │
├─────────────────────────────────────────────────────────────┤
│               Security Layer (Keychain Services)             │
└─────────────────────────────────────────────────────────────┘
```

## Core Features & Capabilities

### 1. Remote Development Environment

The app transforms iOS devices into powerful development terminals by providing:

- **SSH Connectivity**: Secure connections to any SSH-enabled server
- **Multi-Server Support**: Manage multiple development servers
- **Project Organization**: Create and manage projects on remote servers
- **Session Persistence**: Maintain context across app launches

### 2. Claude Code Integration

Advanced AI coding assistance through Claude Code by Anthropic® CLI:

- **Real-time Streaming**: See Claude's responses as they're generated
- **Tool Visualization**: Watch Claude use bash, edit files, read code
- **Session Management**: Maintain conversation context
- **Authentication Flexibility**: Support for API keys and OAuth tokens
- **Error Recovery**: Graceful handling of network and auth issues

### 3. File Management System

Complete remote file system access:

- **File Browser**: Navigate directories with breadcrumb UI
- **CRUD Operations**: Create, rename, delete files and folders
- **Code Viewer**: View source code with syntax highlighting support
- **Smart Navigation**: Respect project boundaries
- **Performance**: Lazy loading for large directories

### 4. Terminal Capabilities (Planned)

Future terminal emulator features:

- **PTY Support**: Full pseudo-terminal emulation
- **ANSI Sequences**: Color and formatting support
- **Command History**: Persistent command history
- **Interactive Programs**: Support for vim, nano, etc.

## Component Deep Dive

### Application Entry Points

#### CodeAgentsMobileApp.swift
The main application entry point that:
- Configures SwiftData model container
- Initializes all data models (RemoteProject, Server, Message, SSHKey)
- Sets up the environment for ContentView
- Manages application lifecycle

#### ContentView.swift
The root navigation controller that:
- Switches between project selection and main interface
- Manages tab-based navigation (Chat, Files, Terminal)
- Configures shared service managers
- Handles navigation state based on active project

### Core Views

#### ChatView & ChatViewModel
**Purpose**: Primary interface for Claude Code interaction

**ChatView Capabilities**:
- Multi-line text input with keyboard management
- Real-time message streaming visualization
- Automatic scroll-to-bottom during streaming
- Keyboard dismissal with tap gesture
- Clear chat functionality
- Installation status handling

**ChatViewModel Functions**:
- `sendMessage()`: Initiates Claude Code conversation with streaming
- `clearChat()`: Removes all messages and resets session
- `loadMessages()`: Fetches historical messages for project
- `updateStreamingMessage()`: Real-time UI updates during streaming
- `createToolResultBlock()`: Processes tool execution results

**State Management**:
- Maintains message array with SwiftData persistence
- Tracks streaming state with dedicated properties
- Handles interrupted messages gracefully
- Manages error states with user-friendly messages

#### FileBrowserView & FileBrowserViewModel
**Purpose**: Remote file system navigation and management

**FileBrowserView Capabilities**:
- Hierarchical navigation with breadcrumbs
- Swipe-to-delete with confirmation
- Context menus for file operations
- Modal sheets for file/folder creation
- Pull-to-refresh functionality
- File content viewer

**FileBrowserViewModel Functions**:
- `loadRemoteFiles()`: Fetches directory listing via SSH
- `navigateTo()`: Path-based navigation with validation
- `createFolder()`: Remote directory creation
- `deleteNode()`: File/folder deletion with SSH
- `renameNode()`: Remote file renaming
- `loadFileContent()`: Retrieves file contents for viewing

**Key Features**:
- Respects project root boundaries
- Handles special characters in filenames
- Provides file metadata (size, modification date)
- Supports nested directory structures

#### ProjectsView & ProjectsViewModel
**Purpose**: Project lifecycle management

**ProjectsView Capabilities**:
- Lists all projects with server information
- Add new project workflow
- Delete projects with optional server cleanup
- Quick project switching
- Empty state with clear CTA

**Key Functions**:
- Project creation with permission validation
- Server-side directory management
- Last accessed tracking
- Resource preparation on activation

### Message Components

#### MessageBubble
Renders individual messages with:
- Role-based styling (user vs assistant)
- Streaming vs completed states
- Smart timestamp formatting
- Structured content support

#### ContentBlockView
Dispatches rendering based on content type:
- Text blocks with markdown
- Tool use visualization
- Tool result display
- System messages
- Error highlighting

#### ToolUseView
Specialized rendering for Claude Code's tool usage:
- Icon and color coding by tool type
- Collapsible parameter display
- Inline diff visualization for edits
- Auto-rotation animation during execution
- Special handling for TodoWrite tasks

#### ToolResultView
Displays tool execution results:
- Expandable/collapsible interface
- Error state highlighting
- Diff formatting for file changes
- Auto-expansion for errors
- Result truncation for large outputs

## Services Layer

### SSHService
**Purpose**: Connection pooling and SSH session management

**Key Functions**:
- `connect(to:purpose:)`: Creates direct server connections
- `getConnection(for:purpose:)`: Retrieves or creates pooled connections
- `isConnectionActive()`: Checks connection status
- `closeConnections()`: Graceful connection teardown

**Implementation Details**:
- Connection pooling by (projectId, purpose) tuple
- Three connection purposes: claude, terminal, fileOperations
- Automatic shell detection and profile loading
- Graceful cleanup on disconnection

### ClaudeCodeService
**Purpose**: Claude Code CLI integration with streaming support

**Key Functions**:
- `checkClaudeInstallation()`: Verifies Claude CLI availability
- `sendMessage()`: Sends messages and streams responses
- `getCurrentAuthMethod()`: Returns active auth configuration
- `hasCredentials()`: Validates authentication setup

**Streaming Architecture**:
- Line-buffered JSON parsing
- Real-time UI updates
- Session ID capture and persistence
- Timeout detection for hung processes
- Error enhancement for better UX

### SwiftSHService
**Purpose**: SwiftNIO SSH implementation wrapper

**Key Functions**:
- `connect()`: Establishes SSH connections
- `execute()`: Runs commands with shell environment
- `startProcess()`: Long-running process management
- `uploadFile()`/`downloadFile()`: Base64 file transfers
- `listDirectory()`: Structured directory listings

**Technical Implementation**:
- SwiftNIO event loop integration
- Channel handler pipeline
- Multiple authentication methods
- Shell detection caching
- Login shell initialization

### ProjectService
**Purpose**: Remote project operations

**Key Functions**:
- `createProject()`: Creates project directories on servers
- `deleteProject()`: Removes projects with validation

**Safety Features**:
- Permission validation before operations
- Fallback path handling
- Special character escaping
- Connection reuse for efficiency

### ServerManager
**Purpose**: Server configuration management

**Key Functions**:
- `loadServers()`: Fetches servers from SwiftData
- `server(withId:)`: UUID-based server lookup
- `updateServers()`: Manual server list refresh

**Implementation**:
- SwiftData integration with FetchDescriptor
- Observable for UI updates
- Sorted results by name

### KeychainManager
**Purpose**: Secure credential storage

**Key Functions**:
- Password storage/retrieval for servers
- API key management for Claude
- OAuth token handling
- SSH key and passphrase storage

**Security Features**:
- iCloud Keychain sync for SSH keys
- Different access control levels
- UTF-8 encoding for all strings
- Atomic update operations

## User Interface Components

### Navigation Architecture
- **Root Navigation**: ContentView manages project vs main UI
- **Tab Navigation**: Three main sections (Chat, Files, Terminal)
- **Modal Presentation**: Sheets for data entry and settings
- **Contextual Navigation**: Breadcrumbs in file browser

### Design Patterns

#### State Management
- `@Observable` macro for ViewModels
- `@StateObject` for service references
- `@State` for local UI state
- `@Environment` for SwiftData context

#### UI Patterns
- **Empty States**: Clear CTAs when no data
- **Loading States**: Progress indicators during operations
- **Error States**: User-friendly error messages
- **Progressive Disclosure**: Expandable sections
- **Gesture Support**: Swipe actions and tap dismissal

### Custom UI Components

#### ConnectionStatusView
- Minimal toolbar button
- Shows active project name
- One-tap navigation to projects

#### ClaudeNotInstalledView
- Installation instructions
- Platform-specific guidance
- Retry functionality

#### AddServerSheet
- Server configuration form
- Authentication method selection
- SSH key import workflow

## Data Models & Persistence

### SwiftData Models

#### RemoteProject
- Unique identifier
- Project name and path
- Server relationship
- Creation timestamp
- Last accessed date
- Claude session ID

#### Server
- Server configuration
- Host and port
- Username
- Authentication type
- SSH key reference
- Projects relationship

#### Message
- Chat message storage
- Role (user/assistant)
- Content blocks
- Project relationship
- Timestamp
- Metadata

#### SSHKey
- Key name and content
- Associated servers
- Passphrase support
- Import date

### Content Models

#### MessageContent
- Structured content parsing
- Multiple block types
- Text, tool use, tool results
- Metadata handling

#### ContentBlock
- Enumerated content types
- Associated data
- Rendering hints

## Security Architecture

### Credential Management
- **Keychain Integration**: All sensitive data in iOS Keychain
- **iCloud Sync**: SSH keys sync across devices
- **Access Control**: Appropriate security levels
- **No Hardcoded Secrets**: Dynamic credential loading

### Authentication Methods
- **Password Authentication**: Secure password storage
- **SSH Key Authentication**: Support for RSA, ECDSA, Ed25519
- **API Key Storage**: Claude Code API key in keychain
- **OAuth Tokens**: Secure token management

### Network Security
- **SSH Protocol**: Encrypted communication
- **Host Key Validation**: Currently accepts all (dev mode)
- **Session Management**: Proper cleanup on disconnect

## Networking & Communication

### SSH Architecture
- **Connection Pooling**: Reuse connections by purpose
- **Channel Handlers**: SwiftNIO pipeline processing
- **Error Recovery**: Graceful reconnection handling
- **Timeout Management**: Configurable command timeouts

### Streaming JSON Protocol
- **Line-Buffered Parsing**: Handles partial JSON
- **Real-time Updates**: Progressive UI rendering
- **Error Detection**: Enhanced error messages
- **Metadata Extraction**: Session IDs and errors

### File Transfer
- **Base64 Encoding**: Reliable binary transfers
- **Chunked Processing**: Memory-efficient operations
- **Progress Tracking**: Future progress indicators

## Key Algorithms & Patterns

### Connection Pooling Algorithm
```swift
// Pseudo-code representation
ConnectionKey = (projectId: UUID, purpose: ConnectionPurpose)
connectionPool: [ConnectionKey: SSHSession]

func getConnection(project, purpose):
    key = ConnectionKey(project.id, purpose)
    if let existing = connectionPool[key], existing.isActive:
        return existing
    else:
        newConnection = createConnection(project.server)
        connectionPool[key] = newConnection
        return newConnection
```

### Streaming JSON Parser
```swift
// Buffer accumulation pattern
var lineBuffer = ""
for chunk in stream:
    lineBuffer += chunk
    while let newlineIndex = lineBuffer.firstIndex(of: "\n"):
        let line = lineBuffer[..<newlineIndex]
        processJSONLine(line)
        lineBuffer.removeSubrange(...newlineIndex)
```

### File Path Validation
```swift
// Boundary checking algorithm
func isWithinProjectBounds(path, projectRoot):
    let resolved = path.standardized
    return resolved.hasPrefix(projectRoot.standardized)
```

## Current Limitations & Future Roadmap

### Current Limitations
1. **Terminal**: Placeholder implementation only
2. **File Editing**: View-only, no editing capability
3. **Syntax Highlighting**: Not yet implemented
4. **Host Key Validation**: Accepts all hosts
5. **Offline Mode**: Requires active connection

### Future Enhancements

#### Phase 1: Terminal Implementation
- Full PTY support with SwiftNIO
- ANSI escape sequence processing
- Command history persistence
- Copy/paste functionality

#### Phase 2: Code Editor
- Syntax highlighting engine
- Code completion support
- Find and replace
- Multi-file editing

#### Phase 3: Advanced Features
- Biometric authentication
- Offline mode with sync
- Multi-window support (iPad)
- Extension system
- Git integration

#### Phase 4: Collaboration
- Shared sessions
- Real-time collaboration
- Code review features
- Team management

### Performance Optimizations
- Lazy loading for large directories
- Connection pooling for efficiency
- Streaming for real-time feedback
- Caching for repeated operations

## Conclusion

CodeAgents represents a significant advancement in mobile development tools, bringing desktop-class capabilities to iOS devices. Its architecture demonstrates modern Swift best practices, thoughtful security design, and a deep understanding of developer workflows. The app successfully bridges the gap between mobile convenience and professional development needs, enabling developers to be productive from anywhere with Claude Code by Anthropic®.

The modular architecture and protocol-based design ensure the codebase remains maintainable and extensible as new features are added. With its solid foundation in place, CodeAgents is well-positioned to evolve into a comprehensive mobile development platform.