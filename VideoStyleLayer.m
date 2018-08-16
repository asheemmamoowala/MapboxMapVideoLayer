//
//  VideoStyleLayer.m
//  MapboxMapVideoLayer
//
//  Created by Asheem Mamoowala on 8/15/18.
//  Copyright © 2018 Mapbox. All rights reserved.
//

#import "VideoStyleLayer.h"

#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>
#import <AVFoundation/AVFoundation.h>

#if defined SAVE_DEBUG_FRAMES
#import <UIKit/UIKit.h>
#endif

NS_INLINE MGLCoordinateBounds MGLCoordinateBoundsForQuad(MGLCoordinateQuad quad) {
    CLLocationDegrees s = fmin(
        fmin(quad.topLeft.latitude, quad.topRight.latitude),
        fmin(quad.bottomLeft.latitude, quad.bottomRight.latitude));
    CLLocationDegrees w = fmin(
        fmin(quad.topLeft.longitude, quad.topRight.longitude),
        fmin(quad.bottomLeft.longitude, quad.bottomRight.longitude));
    CLLocationDegrees n = fmax(
        fmax(quad.topLeft.latitude, quad.topRight.latitude),
        fmax(quad.bottomLeft.latitude, quad.bottomRight.latitude));
    CLLocationDegrees e = fmax(
        fmax(quad.topLeft.longitude, quad.topRight.longitude),
        fmax(quad.bottomLeft.longitude, quad.bottomRight.longitude));
    return MGLCoordinateBoundsMake(CLLocationCoordinate2DMake(s, w),
        CLLocationCoordinate2DMake( n, e ));
}

@implementation VideoStyleLayer {
    GLuint _program;
    GLuint _vertexShader;
    GLuint _fragmentShader;
    GLuint _buffer;
    GLuint _aPos, _aTexPos;
    GLuint _image0;
    GLuint _videoFrameTexture;
    GLuint _vertexBuffer;
    GLuint _textureBuffer;

    AVAssetReader *_movieReader;
    GLuint _umatrix, _uZoom;

    NSURL * _videoUrl;
    MGLCoordinateBounds _bounds;
    MGLCoordinateQuad _quad;
    NSTimer * videoFrameTimer;

}
@synthesize loopVideo = _loopVideo;

- (instancetype)initWithIdentifier:(NSString *)identifier videoURL:(nullable NSURL *)videoURL coordinateQuad:(MGLCoordinateQuad)coords {
    self = [self initWithIdentifier:identifier];
    _quad = coords;
    _videoUrl = videoURL;
    _bounds = MGLCoordinateBoundsForQuad(_quad);
    _loopVideo = YES;
    return self;
}

- (void)didMoveToMapView:(MGLMapView *)mapView {
    [self initShaders];
    [self startVideo];
}

- (void)willMoveFromMapView:(MGLMapView *)mapView {
    [self stopVideo];
    [self clearShaders];
}

- (void)drawInMapView:(MGLMapView *)mapView withContext:(MGLStyleLayerDrawingContext)context {
    if (MGLCoordinateBoundsIntersectsCoordinateBounds(_bounds,
            mapView.visibleCoordinateBounds)) {
        [self renderVideoFrameWithContext:context];
    }
}

- (void)initShaders {
    static const GLchar * vertexShaderSource =
    "precision highp float;attribute vec2 a_pos;attribute vec2 a_texture_pos;varying vec2 v_pos0;uniform mat4 u_matrix;uniform float u_zoom;void main() {vec2 p_pos;p_pos.x = 180.0 + a_pos.x;p_pos.y = 180.0 - degrees(log(tan(3.141592653589793/4.0 + 0.5 * radians(a_pos.y))));float scale = pow(2.0, u_zoom) * 512.0 / 360.0;vec2 x_pos = p_pos * scale;gl_Position = u_matrix * vec4(x_pos, 0, 1);v_pos0 = a_texture_pos;}";

    static const GLchar *fragmentShaderSource = "precision highp float;uniform sampler2D u_image0; varying vec2 v_pos0; void main() { gl_FragColor = texture2D(u_image0, v_pos0); }";

    _program = glCreateProgram();
    _vertexShader = glCreateShader(GL_VERTEX_SHADER);
    _fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(_vertexShader, 1, &vertexShaderSource, NULL);
    glCompileShader(_vertexShader);;
    glAttachShader(_program, _vertexShader);
    glShaderSource(_fragmentShader, 1, &fragmentShaderSource, NULL);
    glCompileShader(_fragmentShader);
    glAttachShader(_program, _fragmentShader);
    glLinkProgram(_program);

    _aPos = glGetAttribLocation(_program, "a_pos");
    _aTexPos = glGetAttribLocation(_program, "a_texture_pos");
    _image0 = glGetUniformLocation(_program, "u_image0");
    _umatrix = glGetUniformLocation(_program, "u_matrix");
    _uZoom = glGetUniformLocation(_program, "u_zoom");

    static const GLfloat textureVertices[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f
    };

    glGenBuffers(1, &_textureBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, _textureBuffer);
    glBufferData(GL_ARRAY_BUFFER, 8 * sizeof(GLfloat), textureVertices, GL_STATIC_DRAW);
    [self readNextMovieFrame];
}

- (void)clearShaders {
    if (!_program) {
        return;
    }

    glDeleteBuffers(1, &_buffer);
    glDetachShader(_program, _vertexShader);
    glDetachShader(_program, _fragmentShader);
    glDeleteShader(_vertexShader);
    glDeleteShader(_fragmentShader);
    glDeleteProgram(_program);
}

-(void) renderVideoFrameWithContext:(MGLStyleLayerDrawingContext)context {
    [self readNextMovieFrame];

    glUseProgram(_program);

    //Set the zoom level used for Mercator projection
    glUniform1f(_uZoom, (float)context.zoomLevel);

    //MGLStyleLayerDrawingContext.projectionMatrix is a double, cast to float
    // for purposes of Gl rendering. This can cause issues at high pitch or zoom.
    GLfloat projMatrix[16];
    projMatrix[0] = (float)context.projectionMatrix.m00;
    projMatrix[1] = (float)context.projectionMatrix.m01;
    projMatrix[2] = (float)context.projectionMatrix.m02;
    projMatrix[3] = (float)context.projectionMatrix.m03;
    projMatrix[4] = (float)context.projectionMatrix.m10;
    projMatrix[5] = (float)context.projectionMatrix.m11;
    projMatrix[6] = (float)context.projectionMatrix.m12;
    projMatrix[7] = (float)context.projectionMatrix.m13;
    projMatrix[8] = (float)context.projectionMatrix.m20;
    projMatrix[9] = (float)context.projectionMatrix.m21;
    projMatrix[10] = (float)context.projectionMatrix.m22;
    projMatrix[11] = (float)context.projectionMatrix.m23;
    projMatrix[12] = (float)context.projectionMatrix.m30;
    projMatrix[13] = (float)context.projectionMatrix.m31;
    projMatrix[14] = (float)context.projectionMatrix.m32;
    projMatrix[15] = (float)context.projectionMatrix.m33;

    //Set the projection matrix
    glUniformMatrix4fv(_umatrix, 1, GL_FALSE, projMatrix);

    //Set the vertex coordiantes:
    CLLocationCoordinate2D nw = _quad.topLeft;
    CLLocationCoordinate2D ne = _quad.topRight;
    CLLocationCoordinate2D se = _quad.bottomRight;
    CLLocationCoordinate2D sw = _quad.bottomLeft;

    GLfloat videoVertices[] = {
        sw.longitude, sw.latitude,
        se.longitude, se.latitude,
        nw.longitude, nw.latitude,
        ne.longitude, ne.latitude};

    glGenBuffers(1, &_buffer);
    glBindBuffer(GL_ARRAY_BUFFER, _buffer);
    glBufferData(GL_ARRAY_BUFFER, 8 * sizeof(GLfloat), videoVertices, GL_STATIC_DRAW);

    glBindBuffer(GL_ARRAY_BUFFER, _buffer);
    glEnableVertexAttribArray(_aPos);
    glVertexAttribPointer(_aPos, 2, GL_FLOAT, GL_FALSE, 0, NULL);

    glBindBuffer(GL_ARRAY_BUFFER, _textureBuffer);
    glEnableVertexAttribArray(_aTexPos);
    glVertexAttribPointer(_aTexPos, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture( GL_TEXTURE_2D, _videoFrameTexture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);

    glUniform1i(_image0, 0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

}
-(void)update:(NSTimer *)timer {
    [self setNeedsDisplay];
}

- (void)startVideo {
    //Loads a locally stored video URL using the AVFoundation APIs
//    AVPlayerItem *pItem = [AVPlayerItem playerItemWithURL:theStreamURL];
//    [playerItem addObserver:self forKeyPath:@"status" options:0 context:nil];
//    AVPlayer *player = [AVPlayer playerWithPlayerItem:pItem];
    NSDictionary * options = [NSDictionary dictionaryWithObject: [NSNumber numberWithBool:NO] forKey:AVURLAssetAllowsCellularAccessKey];
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:_videoUrl options:options];
    assert([asset tracksWithMediaCharacteristic:AVMediaCharacteristicVisual]);
    
    [asset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler:
     ^{
         dispatch_async(dispatch_get_main_queue(),
        ^{
            AVAssetTrack * videoTrack = nil;
            NSArray * tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] == 1)
            {
                videoTrack = [tracks objectAtIndex:0];
                NSError * error = nil;
                self->_movieReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];

                if (error) {
                    NSLog(@"%@", error.localizedDescription);
                }
                
                NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
                NSNumber* value = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA];
                NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:value forKey:key];
                
                [self->_movieReader addOutput:[AVAssetReaderTrackOutput
                                         assetReaderTrackOutputWithTrack:videoTrack
                                         outputSettings:videoSettings]];
                [self->_movieReader startReading];
                
                //Limit to 60 fps.
                double frameRate = fmin(videoTrack.nominalFrameRate, 60);
                
                //Use a conservative frame rate if the video doesn
                self->videoFrameTimer = [NSTimer scheduledTimerWithTimeInterval: 1.0/frameRate
                    target:self
                    selector:@selector(update:)
                    userInfo:nil
                    repeats:YES];

            }
        });
     }];
}

- (void) readNextMovieFrame {
    if (_movieReader.status == AVAssetReaderStatusReading)
    {
        AVAssetReaderTrackOutput * output = (AVAssetReaderTrackOutput *)[_movieReader.outputs objectAtIndex:0];
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (sampleBuffer)
        {
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            
            // Lock the image buffer
            CVPixelBufferLockBaseAddress(imageBuffer,0);
            
            // Get information of the image
            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            
            if (!_videoFrameTexture) {
                glGenTextures(1, &self->_videoFrameTexture);
            }
            glBindTexture(GL_TEXTURE_2D, self->_videoFrameTexture);
            // Using BGRA extension to pull in video frame data
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)width, (GLsizei)height, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(imageBuffer));

            // Unlock the image buffer
            CVPixelBufferUnlockBaseAddress(imageBuffer,0);
            CFRelease(sampleBuffer);
        }
    } else if(_movieReader.status == AVAssetReaderStatusCompleted) {
        [self stopVideo];
        if(self.loopVideo == YES) {
            [self startVideo];
        }
    }
}

- (void) stopVideo {
        [videoFrameTimer invalidate];
        _movieReader = nil;
}
@end
