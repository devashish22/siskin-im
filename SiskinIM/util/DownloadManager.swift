//
// DownloadManager.swift
//
// Siskin IM
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import MobileCoreServices
import TigaseSwift

class DownloadManager {
    
    static let instance = DownloadManager();
    
    private let dispatcher = QueueDispatcher(label: "download_manager_queue");
    
    private var inProgress: [URL: Item] = [:];
    
    private var itemDownloadInProgress: [Int] = [];
    
    func downloadInProgress(for url: URL, completionHandler: @escaping (Result<String,DownloadError>)->Void) -> Bool {
        return dispatcher.sync {
            if let item = self.inProgress[url] {
                item.onCompletion(completionHandler);
                return true;
            }
            return false;
        }
    }
    
    func downloadInProgress(for item: ChatAttachment) -> Bool {
        return dispatcher.sync {
            return self.itemDownloadInProgress.contains(item.id);
        }
    }
    
    func download(item: ChatAttachment, maxSize: Int64) -> Bool {
        return dispatcher.sync {
            guard !itemDownloadInProgress.contains(item.id) else {
                return false;
            }
            
            itemDownloadInProgress.append(item.id);
            
            if let hash = Digest.sha1.digest(toHex: item.url.data(using: .utf8)!), var params = Settings.sharedDefaults!.dictionary(forKey: "upload-\(hash)"), let filename = params["name"] as? String {
                var jids: [BareJID] = (params["jids"] as? [String])?.map({ BareJID($0) }) ?? [];

                let sharedFileUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.siskinim.shared")!.appendingPathComponent("upload", isDirectory: true).appendingPathComponent(hash, isDirectory: false);

                var handled = false;
                if jids.contains(item.jid) {
                    jids = jids.filter({ (j) -> Bool in
                        return j != item.jid;
                    });
                    params["jids"] = jids.map({ $0.stringValue });
                    
                    DownloadStore.instance.store(sharedFileUrl, filename: filename, with: "\(item.id)");
                    DBChatHistoryStore.instance.updateItem(for: item.account, with: item.jid, id: item.id, updateAppendix: { appendix in
                        appendix.filesize = params["size"] as? Int;
                        appendix.mimetype = params["mimeType"] as? String;
                        appendix.filename = filename;
                        appendix.state = .downloaded;
                    });
                    handled = true;
                }
                
                if jids.isEmpty || !FileManager.default.fileExists(atPath: sharedFileUrl.path) {
                    Settings.sharedDefaults?.removeObject(forKey: "upload-\(hash)")
                    if FileManager.default.fileExists(atPath: sharedFileUrl.path) {
                        try! FileManager.default.removeItem(at: sharedFileUrl);
                    }
                } else {
                    Settings.sharedDefaults?.set(params, forKey: "upload-\(hash)");
                }
                guard !handled else {
                    self.itemDownloadInProgress = self.itemDownloadInProgress.filter({ (id) -> Bool in
                        return item.id != id;
                    });
                    return true;
                }
            }
            
            let url = URL(string: item.url)!;
            
            let sessionConfig = URLSessionConfiguration.default;
            let session = URLSession(configuration: sessionConfig);
            DownloadManager.retrieveHeaders(session: session, url: url, completionHandler: { headersResult in
                switch headersResult {
                case .success(let suggestedFilename, let expectedSize, let mimeType):
                    let isTooBig = expectedSize > maxSize;
                    
                    DBChatHistoryStore.instance.updateItem(for: item.account, with: item.jid, id: item.id, updateAppendix: { appendix in
                        appendix.filesize = Int(expectedSize);
                        appendix.mimetype = mimeType;
                        appendix.filename = suggestedFilename;
                        if isTooBig {
                            appendix.state = .tooBig;
                        }
                    });
                    
                    guard !isTooBig else {
                        self.dispatcher.async {
                            self.itemDownloadInProgress = self.itemDownloadInProgress.filter({ (id) -> Bool in
                                return item.id != id;
                            });
                        }
                        return;
                    }
                                        
                    DownloadManager.download(session: session, url: url, completionHandler: { result in
                        switch result {
                        case .success(let localUrl, let filename):
                            //let id = UUID().uuidString;
                            DownloadStore.instance.store(localUrl, filename: filename, with: "\(item.id)");
                            DBChatHistoryStore.instance.updateItem(for: item.account, with: item.jid, id: item.id, updateAppendix: { appendix in
                                appendix.state = .downloaded;
                            });
                            self.dispatcher.sync {
                                self.itemDownloadInProgress = self.itemDownloadInProgress.filter({ (id) -> Bool in
                                    return item.id != id;
                                });
                            }
                        case .failure(let err):
                            var statusCode = 0;
                            switch err {
                            case .responseError(let code):
                                statusCode = code;
                            default:
                                break;
                            }
                            DBChatHistoryStore.instance.updateItem(for: item.account, with: item.jid, id: item.id, updateAppendix: { appendix in
                                appendix.state = statusCode == 404 ? .gone : .error;
                            });
                            self.dispatcher.sync {
                                self.itemDownloadInProgress = self.itemDownloadInProgress.filter({ (id) -> Bool in
                                    return item.id != id;
                                });
                            }
                        }
                    });
                    break;
                case .failure(let statusCode):
                    DBChatHistoryStore.instance.updateItem(for: item.account, with: item.jid, id: item.id, updateAppendix: { appendix in
                        appendix.state = statusCode == 404 ? .gone : .error;
                    });
                    self.dispatcher.async {
                        self.itemDownloadInProgress = self.itemDownloadInProgress.filter({ (id) -> Bool in
                            return item.id != id;
                        });
                    }
                }
            })
            return true;
        }
    }
    
    func downloadFile(destination: DownloadStore, as id: String, url: URL, maxSize: Int64, excludedMimetypes: [String], completionHandler: @escaping (Result<String,DownloadError>)->Void) {
        
        dispatcher.async {
            if let item = self.inProgress[url] {
                item.onCompletion(completionHandler);
            } else {
                let item = Item();
                item.onCompletion(completionHandler);
                self.inProgress[url] = item;
                
                self.downloadFile(url: url, maxSize: maxSize, excludedMimetypes: excludedMimetypes) { (result) in
                    self.dispatcher.async {
                        switch result {
                        case .success(let localUrl, let filename):
                            //let id = UUID().uuidString;
                            destination.store(localUrl, filename: filename, with: id);
                            item.completed(with: .success(id))
                        case .failure(let err):
                            item.completed(with: .failure(err));
                        }
                    }
                }
            }
        }
    }
    
    func downloadFile(url: URL, maxSize: Int64, excludedMimetypes: [String], completionHandler: @escaping (Result<(URL,String),DownloadError>)->Void) {
        let sessionConfig = URLSessionConfiguration.default;
        let session = URLSession(configuration: sessionConfig);
        
        DownloadManager.retrieveHeaders(session: session, url: url, completionHandler: { headersResult in
            switch headersResult {
            case .success(let suggestedFilename, let expectedSize, let mimeType):
                if let type = mimeType {
                    guard !excludedMimetypes.contains(type) else {
                        completionHandler(.failure(.badMimeType(mimeType: type)));
                        return;
                    }
                }
                
                DownloadManager.download(session: session, url: url, completionHandler: completionHandler);
                break;
            case .failure(let statusCode):
                completionHandler(.failure(.responseError(statusCode: statusCode)));
            }
        })
    }
    
    static func download(session: URLSession, url: URL, completionHandler: @escaping (Result<(URL,String), DownloadError>)->Void) {
        let request = URLRequest(url: url);
        let task = session.downloadTask(with: request) { (tempLocalUrl, response, error) in
            if let tempLocalUrl = tempLocalUrl, error == nil {
                if let filename = response?.suggestedFilename {
                    completionHandler(.success((tempLocalUrl, filename)));
                } else if let mimeType = response?.mimeType, let filenameExt = DownloadManager.mimeTypeToExtension(mimeType: mimeType) {
                    completionHandler(.success((tempLocalUrl, "file.\(filenameExt)")));
                } else if let uti = try? tempLocalUrl.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier, let filenameExt = UTTypeCopyPreferredTagWithClass(uti as CFString, kUTTagClassFilenameExtension)?.takeRetainedValue() as String? {
                    completionHandler(.success((tempLocalUrl, "file.\(filenameExt)")));
                } else {
                    completionHandler(.success((tempLocalUrl, tempLocalUrl.lastPathComponent)));
                }
            } else {
                guard error == nil else {
                    completionHandler(.failure(.networkError(error: error!)));
                    return;
                }
                
                completionHandler(.failure(.responseError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)));
            }
        }
        task.resume();
    }
    
    static func mimeTypeToExtension(mimeType: String) -> String? {
        let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimeType as CFString, nil)
        guard let fileUTI = uti?.takeRetainedValue(),
            let fileExtension = UTTypeCopyPreferredTagWithClass(fileUTI, kUTTagClassFilenameExtension) else { return nil }

        let extensionString = String(fileExtension.takeRetainedValue())
        return extensionString
    }
    
    static func retrieveHeaders(session: URLSession, url: URL, completionHandler: @escaping (HeadersResult)->Void) {
        var request = URLRequest(url: url);
        request.httpMethod = "HEAD";
        session.dataTask(with: request) { (data, resp, error) in
            guard let response = resp as? HTTPURLResponse else {
                completionHandler(.failure(statusCode: 500));
                return;
            }
            
            switch response.statusCode {
            case 200:
                completionHandler(.success(suggestedFilename: response.suggestedFilename, expectedSize: response.expectedContentLength, mimeType: response.mimeType))
            default:
                completionHandler(.failure(statusCode: response.statusCode));
            }
        }.resume();
    }
    
    class Item {
        let operationQueue = OperationQueue();
        var result: Result<String,DownloadError>? = nil;
        
        init() {
            self.operationQueue.isSuspended = true;
        }
        
        func onCompletion(_ completionHandler: @escaping (Result<String,DownloadError>)->Void) {
            operationQueue.addOperation {
                completionHandler(self.result ?? .failure(DownloadError.responseError(statusCode: 500)));
            }
        }
        
        func completed(with result: Result<String,DownloadError>?) {
            self.result = result;
            operationQueue.isSuspended = false;
        }
    }
    
    enum HeadersResult {
        case success(suggestedFilename: String?, expectedSize: Int64, mimeType: String?)
        case failure(statusCode: Int)
    }
        
    enum DownloadError: Error {
        case networkError(error: Error)
        case responseError(statusCode: Int)
        case tooBig(size: Int64, mimeType: String?, filename: String?)
        case badMimeType(mimeType: String?)
    }
}
