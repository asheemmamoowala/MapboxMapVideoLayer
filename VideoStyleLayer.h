//
//  VideoStyleLayer.h
//  MapboxMapVideoLayer
//
//  Created by Asheem Mamoowala on 8/15/18.
//  Copyright © 2018 Mapbox. All rights reserved.
//

#ifndef VideoStyleLayer_h
#define VideoStyleLayer_h

#import <Mapbox/Mapbox.h>

@interface VideoStyleLayer : MGLOpenGLStyleLayer
- (instancetype)initWithIdentifier:(NSString *)identifier videoURL:(nullable NSURL *)videoURL coordinateQuad:(MGLCoordinateQuad)coords;
//Defaults to true
@property (nonatomic, assign) BOOL loopVideo;

@end

#endif /* VideoStyleLayer_h */

