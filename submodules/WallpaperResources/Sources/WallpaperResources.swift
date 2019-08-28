import Foundation
import UIKit
import SwiftSignalKit
import Display
import Postbox
import TelegramCore
import MediaResources
import ImageBlur
import TinyThumbnail
import PhotoResources
import LocalMediaResources
import TelegramPresentationData

private func wallpaperDatas(account: Account, accountManager: AccountManager, fileReference: FileMediaReference? = nil, representations: [ImageRepresentationWithReference], alwaysShowThumbnailFirst: Bool = false, thumbnail: Bool = false, autoFetchFullSize: Bool = false, synchronousLoad: Bool = false) -> Signal<(Data?, Data?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(representations.map({ $0.representation })), let largestRepresentation = largestImageRepresentation(representations.map({ $0.representation })), let smallestIndex = representations.firstIndex(where: { $0.representation == smallestRepresentation }), let largestIndex = representations.firstIndex(where: { $0.representation == largestRepresentation }) {
        
        let maybeFullSize: Signal<MediaResourceData, NoError>
        if thumbnail, let file = fileReference?.media {
            maybeFullSize = combineLatest(accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false, attemptSynchronously: synchronousLoad),  account.postbox.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false, attemptSynchronously: synchronousLoad))
            |> mapToSignal { maybeSharedData, maybeData -> Signal<MediaResourceData, NoError> in
                if maybeSharedData.complete {
                    return .single(maybeSharedData)
                } else if maybeData.complete {
                    return .single(maybeData)
                } else {
                    return combineLatest(accountManager.mediaBox.resourceData(file.resource), account.postbox.mediaBox.resourceData(file.resource))
                    |> mapToSignal { maybeSharedData, maybeData -> Signal<MediaResourceData, NoError> in
                        if maybeSharedData.complete {
                            return accountManager.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: true)
                        }
                        else if maybeData.complete {
                            return account.postbox.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: true)
                        } else {
                            return .single(maybeData)
                        }
                    }
                }
            }
        } else {
            if thumbnail {
                maybeFullSize = combineLatest(accountManager.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false), account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: false))
                |> mapToSignal { maybeSharedData, maybeData -> Signal<MediaResourceData, NoError> in
                    if maybeSharedData.complete {
                        return .single(maybeSharedData)
                    } else if maybeData.complete {
                        return .single(maybeData)
                    } else {
                        return account.postbox.mediaBox.resourceData(largestRepresentation.resource)
                    }
                }
            } else {
                maybeFullSize = combineLatest(accountManager.mediaBox.resourceData(largestRepresentation.resource), account.postbox.mediaBox.resourceData(largestRepresentation.resource))
                |> map { sharedData, data -> MediaResourceData in
                    if sharedData.complete {
                        return sharedData
                    } else {
                        return data
                    }
                }
            }
        }
        let decodedThumbnailData = fileReference?.media.immediateThumbnailData.flatMap(decodeTinyThumbnail)
        
        let signal = maybeFullSize
        |> take(1)
        |> mapToSignal { maybeData -> Signal<(Data?, Data?, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                if alwaysShowThumbnailFirst, let decodedThumbnailData = decodedThumbnailData {
                    return .single((decodedThumbnailData, nil, false))
                    |> then(.complete() |> delay(0.05, queue: Queue.concurrentDefaultQueue()))
                    |> then(.single((nil, loadedData, true)))
                } else {
                    return .single((nil, loadedData, true))
                }
            } else {
                let fetchedThumbnail: Signal<FetchResourceSourceType, FetchResourceError>
                if let _ = decodedThumbnailData {
                    fetchedThumbnail = .complete()
                } else {
                    fetchedThumbnail = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: representations[smallestIndex].reference)
                }
                
                let fetchedFullSize = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: representations[largestIndex].reference)
                
                let thumbnailData: Signal<Data?, NoError>
                if let decodedThumbnailData = decodedThumbnailData {
                    thumbnailData = .single(decodedThumbnailData)
                } else {
                    thumbnailData = Signal<Data?, NoError> { subscriber in
                        let fetchedDisposable = fetchedThumbnail.start()
                        let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource).start(next: { next in
                            subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                        
                        return ActionDisposable {
                            fetchedDisposable.dispose()
                            thumbnailDisposable.dispose()
                        }
                    }
                }
                
                var fullSizeData: Signal<(Data?, Bool), NoError>
                if autoFetchFullSize {
                    fullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                        let fetchedFullSizeDisposable = fetchedFullSize.start()
                        
                        let fullSizeDisposable = account.postbox.mediaBox.resourceData(largestRepresentation.resource).start(next: { next in
                            subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                        
                        return ActionDisposable {
                            fetchedFullSizeDisposable.dispose()
                            fullSizeDisposable.dispose()
                        }
                    }
                } else {
                    fullSizeData = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
                    |> map { next -> (Data?, Bool) in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                    }
                }
                
                if thumbnail, let file = fileReference?.media {
                    let betterThumbnailData = account.postbox.mediaBox.cachedResourceRepresentation(file.resource, representation: CachedScaledImageRepresentation(size: CGSize(width: 720.0, height: 720.0), mode: .aspectFit), complete: false, fetch: true)
                    |> map { next -> (Data?, Bool) in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete)
                    } |> filter { (data, _) -> Bool in
                        return data != nil
                    }
                    
                    return thumbnailData |> mapToSignal { thumbnailData in
                        return fullSizeData |> mapToSignal { (fullSizeData, complete) in
                            if complete {
                                return .single((thumbnailData, fullSizeData, complete))
                                |> then(
                                    betterThumbnailData |> map { (betterFullSizeData, complete) in
                                        return (thumbnailData, betterFullSizeData ?? fullSizeData, complete)
                                    })
                            } else {
                                return .single((thumbnailData, fullSizeData, complete))
                            }
                        }
                    }
                } else {
                
                    return thumbnailData |> mapToSignal { thumbnailData in
                        return fullSizeData |> map { (fullSizeData, complete) in
                            return (thumbnailData, fullSizeData, complete)
                        }
                    }
                }
            }
        } |> filter({ $0.0 != nil || $0.1 != nil })
        return signal
    } else {
        return .never()
    }
}

public func wallpaperImage(account: Account, accountManager: AccountManager, fileReference: FileMediaReference? = nil, representations: [ImageRepresentationWithReference], alwaysShowThumbnailFirst: Bool = false, thumbnail: Bool = false, autoFetchFullSize: Bool = false, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = wallpaperDatas(account: account, accountManager: accountManager, fileReference: fileReference, representations: representations, alwaysShowThumbnailFirst: alwaysShowThumbnailFirst, thumbnail: thumbnail, autoFetchFullSize: autoFetchFullSize, synchronousLoad: synchronousLoad)
    
    return signal
    |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            var imageOrientation: UIImage.Orientation = .up
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        imageOrientation = imageOrientationFromSource(imageSource)
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        imageOrientation = imageOrientationFromSource(imageSource)
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: UIImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                
                let initialThumbnailContextFittingSize = fittedSize.fitted(CGSize(width: 90.0, height: 90.0))
                
                let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                    thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                }
                
                if false, thumbnailContextFittingSize.width > thumbnailContextSize.width {
                    let additionalContextSize = thumbnailContextFittingSize
                    let additionalBlurContext = DrawingContext(size: additionalContextSize, scale: 1.0)
                    additionalBlurContext.withFlippedContext { c in
                        c.interpolationQuality = .default
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: additionalContextSize))
                        }
                    }
                    imageFastBlur(Int32(additionalContextSize.width), Int32(additionalContextSize.height), Int32(additionalBlurContext.bytesPerRow), additionalBlurContext.bytes)
                    blurredThumbnailImage = additionalBlurContext.generateImage()
                } else {
                    blurredThumbnailImage = thumbnailContext.generateImage()
                }
            }
            
            if let blurredThumbnailImage = blurredThumbnailImage, fullSizeImage == nil {
                let context = DrawingContext(size: blurredThumbnailImage.size, scale: blurredThumbnailImage.scale, clear: true)
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)
                    if let cgImage = blurredThumbnailImage.cgImage {
                        c.interpolationQuality = .none
                        drawImage(context: c, image: cgImage, orientation: imageOrientation, in: CGRect(origin: CGPoint(), size: blurredThumbnailImage.size))
                        c.setBlendMode(.normal)
                    }
                }
                return context
            }
            
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage, let cgImage = blurredThumbnailImage.cgImage {
                    c.interpolationQuality = .medium
                    drawImage(context: c, image: cgImage, orientation: imageOrientation, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    drawImage(context: c, image: fullSizeImage, orientation: imageOrientation, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

public enum PatternWallpaperDrawMode {
    case thumbnail
    case fastScreen
    case screen
}

private func patternWallpaperDatas(account: Account, accountManager: AccountManager, representations: [ImageRepresentationWithReference], mode: PatternWallpaperDrawMode, autoFetchFullSize: Bool = false) -> Signal<(Data?, Data?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(representations.map({ $0.representation })), let largestRepresentation = largestImageRepresentation(representations.map({ $0.representation })), let smallestIndex = representations.firstIndex(where: { $0.representation == smallestRepresentation }), let largestIndex = representations.firstIndex(where: { $0.representation == largestRepresentation }) {
        
        let size: CGSize?
        switch mode {
            case .thumbnail:
                size = largestRepresentation.dimensions.fitted(CGSize(width: 640.0, height: 640.0))
            case .fastScreen:
                size = largestRepresentation.dimensions.fitted(CGSize(width: 1280.0, height: 1280.0))
            default:
                size = nil
        }
        let maybeFullSize = combineLatest(accountManager.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: false), account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: false))
        
        let signal = maybeFullSize
        |> take(1)
        |> mapToSignal { maybeSharedData, maybeData -> Signal<(Data?, Data?, Bool), NoError> in
            if maybeSharedData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeSharedData.path), options: [])
                return .single((nil, loadedData, true))
            } else if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((nil, loadedData, true))
            } else {
                let fetchedThumbnail = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: representations[smallestIndex].reference)
                let fetchedFullSize = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: representations[largestIndex].reference)
                
                let thumbnailData = Signal<Data?, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.cachedResourceRepresentation(representations[smallestIndex].representation.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: true).start(next: { next in
                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
                        
                        if next.complete, let data = try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedRead) {
                            accountManager.mediaBox.storeResourceData(representations[smallestIndex].representation.resource.id, data: data)
                            let _ = accountManager.mediaBox.cachedResourceRepresentation(representations[smallestIndex].representation.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: true).start()
                        }
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                let fullSizeData = Signal<(Data?, Bool), NoError> { subscriber in
                    let fetchedFullSizeDisposable = fetchedFullSize.start()
                    let fullSizeDisposable = account.postbox.mediaBox.cachedResourceRepresentation(representations[largestIndex].representation.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: true).start(next: { next in
                        subscriber.putNext((next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []), next.complete))
                        
                        if next.complete, let data = try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedRead) {
                            accountManager.mediaBox.storeResourceData(representations[largestIndex].representation.resource.id, data: data)
                            let _ = accountManager.mediaBox.cachedResourceRepresentation(representations[largestIndex].representation.resource, representation: CachedPatternWallpaperMaskRepresentation(size: size), complete: false, fetch: true).start()
                        }
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedFullSizeDisposable.dispose()
                        fullSizeDisposable.dispose()
                    }
                }
                
                return thumbnailData |> mapToSignal { thumbnailData in
                    return fullSizeData |> map { (fullSizeData, complete) in
                        return (thumbnailData, fullSizeData, complete)
                    }
                }
            }
        }
    
        return signal
    } else {
        return .never()
    }
}

public func patternWallpaperImage(account: Account, accountManager: AccountManager, representations: [ImageRepresentationWithReference], mode: PatternWallpaperDrawMode, autoFetchFullSize: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return patternWallpaperDatas(account: account, accountManager: accountManager, representations: representations, mode: mode, autoFetchFullSize: autoFetchFullSize)
    |> mapToSignal { (thumbnailData, fullSizeData, fullSizeComplete) in
        return patternWallpaperImageInternal(thumbnailData: thumbnailData, fullSizeData: fullSizeData, fullSizeComplete: fullSizeComplete, mode: mode)
    }
}

public func patternWallpaperImageInternal(thumbnailData: Data?, fullSizeData: Data?, fullSizeComplete: Bool, mode: PatternWallpaperDrawMode) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    var prominent = false
    if case .thumbnail = mode {
        prominent = true
    }
    
    var scale: CGFloat = 0.0
    if case .fastScreen = mode {
        scale = max(1.0, UIScreenScale - 1.0)
    }
    
    return .single((thumbnailData, fullSizeData, fullSizeComplete))
    |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData, fullSizeComplete {
                let options = NSMutableDictionary()
                options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                    fullSizeImage = image
                }
            }
            
            if let combinedColor = arguments.emptyColor {
                let color = combinedColor.withAlphaComponent(1.0)
                let intensity = combinedColor.alpha
                
                if fullSizeImage == nil {
                    let context = DrawingContext(size: arguments.drawingSize, scale: 1.0, clear: true)
                    context.withFlippedContext { c in
                        c.setBlendMode(.copy)
                        c.setFillColor(color.cgColor)
                        c.fill(arguments.drawingRect)
                    }
                    
                    addCorners(context, arguments: arguments)
                    
                    return context
                }
                
                let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)
                    c.setFillColor(color.cgColor)
                    c.fill(arguments.drawingRect)
                    
                    if let fullSizeImage = fullSizeImage {
                        c.setBlendMode(.normal)
                        c.interpolationQuality = .medium
                        c.clip(to: fittedRect, mask: fullSizeImage)
                        c.setFillColor(patternColor(for: color, intensity: intensity, prominent: prominent).cgColor)
                        c.fill(arguments.drawingRect)
                    }
                }
                
                addCorners(context, arguments: arguments)
                
                return context
            } else {
                return nil
            }
        }
    }
}

public func patternColor(for color: UIColor, intensity: CGFloat, prominent: Bool = false) -> UIColor {
    var hue:  CGFloat = 0.0
    var saturation: CGFloat = 0.0
    var brightness: CGFloat = 0.0
    if color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil) {
        if saturation > 0.0 {
            saturation = min(1.0, saturation + 0.05 + 0.1 * (1.0 - saturation))
        }
        if brightness > 0.45 {
            brightness = max(0.0, brightness * 0.65)
        } else {
            brightness = max(0.0, min(1.0, 1.0 - brightness * 0.65))
        }
        let alpha = (prominent ? 0.5 : 0.4) * intensity
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
    return .black
}

public func solidColor(_ color: UIColor) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return .single({ arguments in
        let context = DrawingContext(size: arguments.drawingSize, clear: true)
        
        context.withFlippedContext { c in
            c.setFillColor(color.cgColor)
            c.fill(arguments.drawingRect)
        }
        
        addCorners(context, arguments: arguments)
        
        return context
    })
}

private func builtinWallpaperData() -> Signal<UIImage, NoError> {
    return Signal { subscriber in
        if let filePath = frameworkBundle.path(forResource: "ChatWallpaperBuiltin0", ofType: "jpg"), let image = UIImage(contentsOfFile: filePath) {
            subscriber.putNext(image)
        }
        subscriber.putCompletion()
        
        return EmptyDisposable
        } |> runOn(Queue.concurrentDefaultQueue())
}

public func settingsBuiltinWallpaperImage(account: Account) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return builtinWallpaperData() |> map { fullSizeImage in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = fullSizeImage.size.aspectFilled(drawingRect.size)
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if let fullSizeImage = fullSizeImage.cgImage {
                    c.interpolationQuality = .medium
                    drawImage(context: c, image: fullSizeImage, orientation: .up, in: fittedRect)
                }
            }
            
            addCorners(context, arguments: arguments)
            
            return context
        }
    }
}

public func photoWallpaper(postbox: Postbox, photoLibraryResource: PhotoLibraryMediaResource) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let thumbnail = fetchPhotoLibraryImage(localIdentifier: photoLibraryResource.localIdentifier, thumbnail: true)
    let fullSize = fetchPhotoLibraryImage(localIdentifier: photoLibraryResource.localIdentifier, thumbnail: false)
    
    return (thumbnail |> then(fullSize))
    |> map { result in
        var sourceImage = result?.0
        let isThumbnail = result?.1 ?? false
        
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: 1.0, clear: true)
            
            let dimensions = sourceImage?.size
            
            if let thumbnailImage = sourceImage?.cgImage, isThumbnail {
                var fittedSize = arguments.imageSize
                if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                    fittedSize.width = arguments.boundingSize.width
                }
                if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                    fittedSize.height = arguments.boundingSize.height
                }
                
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                
                let initialThumbnailContextFittingSize = fittedSize.fitted(CGSize(width: 100.0, height: 100.0))
                
                let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                imageFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                    thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                }
                
                if thumbnailContextFittingSize.width > thumbnailContextSize.width {
                    let additionalContextSize = thumbnailContextFittingSize
                    let additionalBlurContext = DrawingContext(size: additionalContextSize, scale: 1.0)
                    additionalBlurContext.withFlippedContext { c in
                        c.interpolationQuality = .default
                        if let image = thumbnailContext.generateImage()?.cgImage {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: additionalContextSize))
                        }
                    }
                    imageFastBlur(Int32(additionalContextSize.width), Int32(additionalContextSize.height), Int32(additionalBlurContext.bytesPerRow), additionalBlurContext.bytes)
                    sourceImage = additionalBlurContext.generateImage()
                } else {
                    sourceImage = thumbnailContext.generateImage()
                }
            }
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                if let sourceImage = sourceImage, let cgImage = sourceImage.cgImage, let dimensions = dimensions {
                    let imageSize = dimensions.aspectFilled(arguments.drawingRect.size)
                    let fittedRect = CGRect(origin: CGPoint(x: floor((arguments.drawingRect.size.width - imageSize.width) / 2.0), y: floor((arguments.drawingRect.size.height - imageSize.height) / 2.0)), size: imageSize)
                    c.draw(cgImage, in: fittedRect)
                }
            }
            
            return context
        }
    }
}

public func telegramThemeData(account: Account, accountManager: AccountManager, resource: MediaResource, synchronousLoad: Bool) -> Signal<Data?, NoError> {
    let maybeFetched = accountManager.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad)
    return maybeFetched
    |> take(1)
    |> mapToSignal { maybeData in
        if maybeData.complete {
            let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
            return .single(loadedData)
        } else {
            let data = account.postbox.mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: false)
            return Signal { subscriber in
                let fetch = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: .standalone(resource: resource)).start()
                let disposable = (data
                |> map { data -> Data? in
                    return data.complete ? try? Data(contentsOf: URL(fileURLWithPath: data.path)) : nil
                }).start(next: { next in
                    if let data = next {
                        accountManager.mediaBox.storeResourceData(resource.id, data: data)
                    }
                    subscriber.putNext(next)
                }, error: { error in
                    subscriber.putError(error)
                }, completed: {
                    subscriber.putCompletion()
                })
                return ActionDisposable {
                    fetch.dispose()
                    disposable.dispose()
                }
            }
        }
    }
}

private func generateBackArrowImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 13.0, height: 22.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(color.cgColor)
        
        context.translateBy(x: 0.0, y: -UIScreenPixel)
        
        let _ = try? drawSvgPath(context, path: "M3.60751322,11.5 L11.5468531,3.56066017 C12.1326395,2.97487373 12.1326395,2.02512627 11.5468531,1.43933983 C10.9610666,0.853553391 10.0113191,0.853553391 9.42553271,1.43933983 L0.449102936,10.4157696 C-0.149700979,11.0145735 -0.149700979,11.9854265 0.449102936,12.5842304 L9.42553271,21.5606602 C10.0113191,22.1464466 10.9610666,22.1464466 11.5468531,21.5606602 C12.1326395,20.9748737 12.1326395,20.0251263 11.5468531,19.4393398 L3.60751322,11.5 Z ")
    })
}

public func themeImage(account: Account, accountManager: AccountManager, fileReference: FileMediaReference, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {

    return telegramThemeData(account: account, accountManager: accountManager, resource: fileReference.media.resource, synchronousLoad: synchronousLoad)
    |> map { data in
        let theme: PresentationTheme?
        if let data = data {
            theme = makePresentationTheme(data: data)
        } else {
            theme = nil
        }
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: 0.0, clear: true)
            let drawingRect = arguments.drawingRect
            context.withFlippedContext { c in
                c.setBlendMode(.normal)
                if let theme = theme {
                    if case let .color(value) = theme.chat.defaultWallpaper {
                        c.setFillColor(UIColor(rgb: UInt32(bitPattern: value)).cgColor)
                    } else {
                        c.setFillColor(theme.chatList.backgroundColor.cgColor)
                    }
                    c.fill(drawingRect)
                    
                    c.setFillColor(theme.rootController.navigationBar.backgroundColor.cgColor)
                    c.fill(CGRect(origin: CGPoint(x: 0.0, y: drawingRect.height - 42.0), size: CGSize(width: drawingRect.width, height: 42.0)))
                    
                    c.setFillColor(theme.rootController.navigationBar.separatorColor.cgColor)
                    c.fill(CGRect(origin: CGPoint(x: 1.0, y: drawingRect.height - 43.0), size: CGSize(width: drawingRect.width - 2.0, height: 1.0)))
                    
                    c.setFillColor(theme.rootController.navigationBar.secondaryTextColor.cgColor)
                    c.fillEllipse(in: CGRect(origin: CGPoint(x: drawingRect.width - 28.0 - 7.0, y: drawingRect.height - 7.0 - 28.0 - UIScreenPixel), size: CGSize(width: 28.0, height: 28.0)))
                    
                    if let arrow = generateBackArrowImage(color: theme.rootController.navigationBar.buttonColor), let image = arrow.cgImage {
                        c.draw(image, in: CGRect(x: 9.0, y: drawingRect.height - 11.0 - 22.0 + UIScreenPixel, width: 13.0, height: 22.0))
                    }
                    c.setFillColor(theme.chat.inputPanel.panelBackgroundColor.cgColor)
                    c.fill(CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: drawingRect.width, height: 42.0)))
                    
                    c.setFillColor(theme.chat.inputPanel.panelSeparatorColor.cgColor)
                    c.fill(CGRect(origin: CGPoint(x: 1.0, y: 42.0), size: CGSize(width: drawingRect.width - 2.0, height: 1.0)))
                    
                    c.setFillColor(theme.chat.inputPanel.inputBackgroundColor.cgColor)
                    c.setStrokeColor(theme.chat.inputPanel.inputStrokeColor.cgColor)
                    
                    c.setLineWidth(1.0)
                    let path = UIBezierPath(roundedRect: CGRect(x: 34.0, y: 6.0, width: drawingRect.width - 34.0 * 2.0, height: 31.0), cornerRadius: 15.5)
                    c.addPath(path.cgPath)
                    c.drawPath(using: .fillStroke)
                    
                    if let attachment = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconAttachment"), color: theme.chat.inputPanel.panelControlColor), let image = attachment.cgImage {
                        c.draw(image, in: CGRect(origin: CGPoint(x: 3.0, y: 6.0 + UIScreenPixel), size: attachment.size.fitted(CGSize(width: 30.0, height: 30.0))))
                    }
                    
                    if let microphone = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/IconMicrophone"), color: theme.chat.inputPanel.panelControlColor), let image = microphone.cgImage {
                        c.draw(image, in: CGRect(origin: CGPoint(x: drawingRect.width - 3.0 - 29.0, y: 7.0 + UIScreenPixel), size: microphone.size.fitted(CGSize(width: 30.0, height: 30.0))))
                    }
                    
                    c.saveGState()
                    c.setFillColor(theme.chat.message.incoming.bubble.withoutWallpaper.fill.cgColor)
                    c.setStrokeColor(theme.chat.message.incoming.bubble.withoutWallpaper.stroke.cgColor)
                    c.translateBy(x: 5.0, y: 65.0)
                    c.translateBy(x: 114.0, y: 32.0)
                    c.scaleBy(x: 1.0, y: -1.0)
                    c.translateBy(x: -114.0, y: -32.0)
                    let _ = try? drawSvgPath(c, path: "M98.0061174,0 C106.734138,0 113.82927,6.99200411 113.996965,15.6850616 L114,16 C114,24.836556 106.830179,32 98.0061174,32 L21.9938826,32 C18.2292665,32 14.7684355,30.699197 12.0362474,28.5221601 C8.56516444,32.1765452 -1.77635684e-15,31.9985981 -1.77635684e-15,31.9985981 C5.69252399,28.6991366 5.98604874,24.4421608 5.99940747,24.1573436 L6,24.1422468 L6,16 C6,7.163444 13.1698213,0 21.9938826,0 L98.0061174,0 Z")
                    c.restoreGState()
                    
                    c.saveGState()
                    c.setFillColor(theme.chat.message.outgoing.bubble.withoutWallpaper.fill.cgColor)
                    c.setStrokeColor(theme.chat.message.outgoing.bubble.withoutWallpaper.stroke.cgColor)
                    c.translateBy(x: drawingRect.width - 114.0 - 5.0, y: 25.0)
                    c.translateBy(x: 114.0, y: 32.0)
                    c.scaleBy(x: -1.0, y: -1.0)
                    c.translateBy(x: 0, y: -32.0)
                    let _ = try? drawSvgPath(c, path: "M98.0061174,0 C106.734138,0 113.82927,6.99200411 113.996965,15.6850616 L114,16 C114,24.836556 106.830179,32 98.0061174,32 L21.9938826,32 C18.2292665,32 14.7684355,30.699197 12.0362474,28.5221601 C8.56516444,32.1765452 -1.77635684e-15,31.9985981 -1.77635684e-15,31.9985981 C5.69252399,28.6991366 5.98604874,24.4421608 5.99940747,24.1573436 L6,24.1422468 L6,16 C6,7.163444 13.1698213,0 21.9938826,0 L98.0061174,0 Z")
                    c.restoreGState()
                    
                    c.setStrokeColor(theme.rootController.navigationBar.separatorColor.cgColor)
                    c.setLineWidth(2.0)
                    let borderPath = UIBezierPath(roundedRect: drawingRect, cornerRadius: 4.0)
                    c.addPath(borderPath.cgPath)
                    c.drawPath(using: .stroke)
                } else if let emptyColor = arguments.emptyColor {
                    c.setFillColor(emptyColor.cgColor)
                    c.fill(drawingRect)
                }
            }
            addCorners(context, arguments: arguments)
            return context
        }
    }
}
