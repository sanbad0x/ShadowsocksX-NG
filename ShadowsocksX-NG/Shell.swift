//
//  Shell.swift
//  ShadowsocksX-NG
//
//  Created by cjc on 2017/5/6.
//  Copyright © 2017年 qiuyuzhou. All rights reserved.
//

import Foundation

class Shell {
    
    static func run(command: String) -> [String] {
        
        let task = ShellTask(launchPath: "/bin/sh")
        
        task.arguments = [
            "-c",
            command
        ]
        
        var buffer = Data()
        
        task.outputOptions = [
            .handle { availableData in
                buffer.append(availableData)
            }
        ]
        task.errorOptions = [
            .handle { availableData in
                buffer.append(availableData)
            }
        ]
        
        task.launch { result in
            
            switch result {
            case .success:
                break
            case let .failure(code):
                print("command [\(task)] failed [\(code)]")
            }
            
        }
        
        task.waitUntilExit()
        
        let outputString = NSString(data: buffer as Data, encoding: String.Encoding.utf8.rawValue) as String?
        return outputString?.components(separatedBy: "\n") ?? []
    }
}


//  baseed on code from iam Nichols
final class ShellTask {
    
    enum IOOption {
        case print(prefix: String?)
        case handle(callback: (_ availableData: Data) -> Void)
    }
    
    enum Result {
        case success
        case failure(Int32)
    }
    
    let launchPath: String
    var arguments: [String]? = nil
    var environment: [String: String]?  = nil
    var currentDirectoryPath: String? = nil
    var outputOptions = [IOOption]()
    var errorOptions = [IOOption]()
    
    init(launchPath: String) {
        self.launchPath = launchPath
        self.taskQueue.name = "ShellTask.LaunchQueue"
    }
    
    deinit {
        reset()
    }
    
    fileprivate let taskQueue = OperationQueue()
    fileprivate var notificationTokens = [NSObjectProtocol]()
    fileprivate var task = Process()
    fileprivate var errorPipe = Pipe()
    fileprivate var outputPipe = Pipe()
    fileprivate var errorReachedEOF = false
    fileprivate var outputReachedEOF = false
    fileprivate var errorRecievedData = false
    fileprivate var outputRecievedData = false
    fileprivate var completion: ((_ result: ShellTask.Result) -> Void)?
    
    var terminationStatus: Int32? = nil
    
    var command: String {
        get {
            return launchPath + " " + (arguments?.joined(separator: " "))!
        }
    }
    
    fileprivate func reset() {
        
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        
        task = Process()
        outputPipe = Pipe()
        errorPipe = Pipe()
        outputReachedEOF = false
        errorReachedEOF = false
        outputRecievedData = false
        errorRecievedData = false
        terminationStatus = nil
        completion = nil
    }
    
    var isRunning: Bool {
        return completion != nil
    }
    
    func launch(_ completion: @escaping (_ result: ShellTask.Result) -> Void) {
        
        if isRunning {
            fatalError("The instance of ShellTask has already launched.")
        }
        
        // print("[ShellTask] Launching:", launchPath, arguments?.joined(separator: " ") ?? "")
        
        self.completion = completion
        
        task.launchPath = launchPath
        task.arguments = arguments
        if let environment = environment {
            task.environment = environment
        }
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        if let currentDirectoryPath = self.currentDirectoryPath {
            task.currentDirectoryPath = currentDirectoryPath
        }
        
        taskQueue.addOperation(BlockOperation {
            
            self.setupPipe(self.outputPipe)
            self.setupPipe(self.errorPipe)
            
            self.setupTerminationForTask(self.task)
            
            self.task.launch()
            
            self.waitUntilExit()
            
            DispatchQueue.main.async {
                self.complete()
            }
        })
    }
    
    func waitUntilExit() {
        while !self.hasCompleted() {
            RunLoop.current.run(mode: RunLoopMode.defaultRunLoopMode, before: Date.distantFuture)
        }
    }
    
    fileprivate func complete() {
        
        if let completion = self.completion, let terminationStatus = self.terminationStatus {
            
            if terminationStatus == EXIT_SUCCESS {
                completion(.success)
            } else {
                completion(.failure(terminationStatus))
            }
            
            // self.reset()
            
        } else {
            fatalError("completion or termination status aren't present but the task completed.")
        }
    }
    
    fileprivate func hasCompleted() -> Bool {
        return outputReachedEOF && errorReachedEOF && terminationStatus != nil
    }
}

// MARK: - File Handles
private extension ShellTask {
    
    func setupPipe(_ pipe: Pipe) {
        
        let center = NotificationCenter.default
        let name = NSNotification.Name.NSFileHandleDataAvailable
        let handle = pipe.fileHandleForReading
        let callback = fileHandleDataAvailableBlock
        
        handle.waitForDataInBackgroundAndNotify()
        
        let token = center.addObserver(forName: name, object: handle, queue: taskQueue, using: callback)
        notificationTokens.append(token)
    }
    
    func fileHandleDataAvailableBlock(_ notification: Notification) {
        if let fileHandle = notification.object as? FileHandle {
            fileHandleDataAvailable(fileHandle)
        }
    }
    
    func fileHandleDataAvailable(_ fileHandle: FileHandle) {
        
        let availableData = fileHandle.availableData
        
        if fileHandle === outputPipe.fileHandleForReading {
            processData(availableData, withOptions: outputOptions, initialChunk: !outputRecievedData)
        } else if fileHandle === errorPipe.fileHandleForReading {
            processData(availableData, withOptions: errorOptions, initialChunk: !errorRecievedData)
        }
        
        if availableData.count == 0 {
            fileHandleReachedEOF(fileHandle)
        }
        
        if fileHandle === outputPipe.fileHandleForReading && !outputRecievedData {
            outputRecievedData = true
        } else if fileHandle === errorPipe.fileHandleForReading && !errorRecievedData {
            errorRecievedData = true
        }
        
        fileHandle.waitForDataInBackgroundAndNotify()
    }
    
    func fileHandleReachedEOF(_ fileHandle: FileHandle) {
        
        if fileHandle === outputPipe.fileHandleForReading {
            outputReachedEOF = true
        } else if fileHandle === errorPipe.fileHandleForReading {
            errorReachedEOF = true
        }
    }
}

// MARK: - IOOption
private extension ShellTask {
    
    func processData(_ availableData: Data, withOptions options: [IOOption], initialChunk: Bool) {
        
        for option in options {
            
            switch option {
            case let .print(prefix):
                // print the NSData via `print`
                if let chunk = String(data: availableData, encoding: String.Encoding.utf8) {
                    printChunk(chunk, prefix: prefix, initialChunk: initialChunk, EOF: availableData.count == 0)
                }
                
            case let .handle(callback):
                // pass the data back through the closure
                callback(availableData)
            }
        }
    }
    
    func printChunk(_ chunk: String, prefix: String?, initialChunk: Bool, EOF: Bool) {
        
        if let prefix = prefix , EOF == false {
            
            var output = chunk
            
            if initialChunk == true {
                output = prefix + " " + output
            }
            
            output = output.replacingOccurrences(of: "\n", with: "\n" + prefix + " ")
            
            print(output, separator: "", terminator: "")
            
        } else {
            
            print(chunk, separator: "", terminator: EOF ? "\n" : "")
        }
    }
}

// MARK: - Termination
private extension ShellTask {
    
    func setupTerminationForTask(_ task: Process) {
        
        let center = NotificationCenter.default
        let name = Process.didTerminateNotification
        let callback = taskDidTerminateBlock
        
        let token = center.addObserver(forName: name, object: task, queue: taskQueue, using: callback)
        notificationTokens.append(token)
    }
    
    func taskDidTerminateBlock(_ notification: Notification) {
        if let task = notification.object as? Process {
            taskDidTerminate(task)
        }
    }
    
    func taskDidTerminate(_ task: Process) {
        terminationStatus = task.terminationStatus
    }
}
