import Foundation
import Combine

import Amplify
import AmplifyPlugins

class Backend {
    static let shared = Backend()
    
    @discardableResult
    static func initialize() -> Backend {
        return .shared
    }
    
    // these tokens need to stay around for the time the app is running
    fileprivate var sessionToken : AnyCancellable?
    fileprivate var hubToken     : AnyCancellable?
    fileprivate var queryToken   : AnyCancellable?

    private init() {
        // initialize amplify
        do {
           try Amplify.add(plugin: AWSCognitoAuthPlugin())
           try Amplify.add(plugin: AWSAPIPlugin(modelRegistration: AmplifyModels()))
           try Amplify.add(plugin: AWSS3StoragePlugin())
           try Amplify.configure()
           print("Initialized Amplify")
        } catch {
           print("Could not initialize Amplify: \(error)")
        }
        
        // let's check if user is signedIn or not
        sessionToken = Amplify.Auth.fetchAuthSession()
        .resultPublisher
        .receive(on: DispatchQueue.main) // execute sink on main queue because it updates the UI
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 {
                    print("Fetch auth session failed with error - \(error)")
                }
            },
            receiveValue: { session in
                // let's update UserData and the UI
                self.updateUserData(withSignInStatus: session.isSignedIn)
        })
    
        // listen to auth events.
        // see https://github.com/aws-amplify/amplify-ios/blob/master/Amplify/Categories/Auth/Models/AuthEventName.swift
        hubToken = Amplify.Hub.publisher(for: .auth)
        .compactMap { payload -> Bool? in

            var isSignedIn : Bool? = nil // nil values are not passed down the stream to sink()
            switch payload.eventName {
                case HubPayload.EventName.Auth.signedIn:
                    print("==HUB== User signed In, update UI")
                    isSignedIn = true

                case HubPayload.EventName.Auth.signedOut:
                    print("==HUB== User signed Out, update UI")
                    isSignedIn = false

                case HubPayload.EventName.Auth.sessionExpired:
                    print("==HUB== Session expired, show sign in UI")
                    isSignedIn = false

                default:
                    //print("==HUB== \(payload)")
                    break
            }

            return isSignedIn
        }
        .receive(on: DispatchQueue.main) // execute sink on main queue because it updates the UI
        .sink { isSignedIn in
            // update UI (nil values are not passed down the stream)
            self.updateUserData(withSignInStatus: isSignedIn)
        }
    }
    
    // MARK: Authentication
    // change our internal state, this triggers an UI update on the main thread
    func updateUserData(withSignInStatus status : Bool) {
//        DispatchQueue.main.async() { // not necessary anymore as the thread selection is made by Combine
            let userData : UserData = .shared
            userData.isSignedIn = status

            // when user is signed in, query the database, otherwise empty our model
            if (status && userData.notes.isEmpty) {
                queryToken = self.queryNotes()
            } else {
                userData.notes = []
            }
//        }
    }
    
    public func signIn() -> AnyCancellable? {

        return Amplify.Auth.signInWithWebUI(presentationAnchor: UIApplication.shared.windows.first!)
        .resultPublisher
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 {
                    print("Sign in failed: \(error)")
                }
            },
            receiveValue: { result in
                print("Sign in succeeded: \(result)")
            }
        )
       
    }

    // signout
    public func signOut() -> AnyCancellable? {

        return Amplify.Auth.signOut()
        .resultPublisher
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 {
                    print("Sign out failed with error: \(error)")
                }
            },
            receiveValue: { result in
                print("Successfully signed out: \(result)")
            }
        )
    }
    
    // MARK: API Access
    
    func queryNotes() -> AnyCancellable? {
        
        return Amplify.API.query(request: .list(NoteData.self))
        .resultPublisher
        .receive(on: DispatchQueue.main) // execute sink on main queue because it updates the UI
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 { //other values are .finished
                    print("Can not retrieve Notes : error \(error)")
                }
            },
            receiveValue: { result in
                switch result {
                    case .success(let notesData):
                        print("Successfully retrieved list of Notes")

                        for n in notesData {
                            let note = Note.init(from: n)
                            UserData.shared.notes.append(note)
                        }
                    case .failure(let error):
                        print("Can not retrieve result : error  \(error.errorDescription)")
                }
            }
        )
    }
    
    func createNote(note: Note) -> AnyCancellable? {
        
        return Amplify.API.mutate(request: .create(note.data))
        .resultPublisher
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 { //other values are .finished
                    print("Can not create Note : error \(error)")
                }
            },
            receiveValue: { result in
                switch result {
                    case .success(let data):
                        print("Successfully created note: \(data)")
                    case .failure(let error):
                        print("Unable to create note: \(error)")
                }
            }
        )
    }
    
    func deleteNote(note: Note) -> AnyCancellable? {
        
        return Amplify.API.mutate(request: .delete(note.data))
            .resultPublisher
            .sink(
                receiveCompletion: {
                    if case .failure(let error) = $0 { //other values are .finished
                        print("Can not delete Note : error \(error)")
                    }
                },
                receiveValue: { result in
                    switch result {
                        case .success(let data):
                            print("Successfully deleted note: \(data)")
                        case .failure(let error):
                            print("Unable to delete note: \(error)")
                    }
                }
            )
    }
    
    // MARK: Image Access
    
    func storeImage(name: String, image: Data) -> AnyCancellable? {
    
        let options = StorageUploadDataRequest.Options(accessLevel: .private)
        return Amplify.Storage.uploadData(key: name, data: image, options: options) 
        .resultPublisher // Storage offers a resultPublisher and a progressPublisher to track progress.  I will not use the later
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 { //other values are .finished
                    print("Can not upload image : error \(error)")
                }
            },
            receiveValue: { print($0) }
        )
    }
    
    // TODO remove the callback and use Combine instead
    func retrieveImage(name: String, completed: @escaping (Data) -> Void) -> AnyCancellable? {

        let options = StorageDownloadDataRequest.Options(accessLevel: .private)
        return Amplify.Storage.downloadData(key: name, options: options)
        .resultPublisher // Storage offers a resultPublisher and a progressPublisher to track progress.  I will not use the later
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 { //other values are .finished
                    print("Can not download image : error \(error)")
                }
            },
            receiveValue: { data in
                print("Image \(name) loaded")
                completed(data)
            }
        )
    }

    func deleteImage(name: String) -> AnyCancellable? {
        
        let options = StorageRemoveRequest.Options(accessLevel: .private)
        return Amplify.Storage.remove(key: name, options: options)
        .resultPublisher
        .sink(
            receiveCompletion: {
                if case .failure(let error) = $0 { //other values are .finished
                    print("Can not delete image : error \(error)")
                }
            },
            receiveValue: { data in
                print("Image \(name) deleted")
            }
        )
    }

}
    
