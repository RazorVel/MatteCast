#pragma once
#include <cstddef>
#include <string>
#include <vector>
typedef unsigned char uchar;
#define CV_8UC1 1
#define CV_8UC3 3
namespace cv {
static const int CAP_V4L2=200, CAP_PROP_FRAME_WIDTH=3, CAP_PROP_FRAME_HEIGHT=4, CAP_PROP_FPS=5, CAP_PROP_FOURCC=6;
static const int COLOR_BGR2YUV_I420=1, COLOR_GRAY2BGR=2, FONT_HERSHEY_SIMPLEX=0, IMWRITE_JPEG_QUALITY=1, IMREAD_COLOR=1;
struct Size { int width,height; Size(int w=0,int h=0):width(w),height(h){} };
struct Point { int x,y; Point(int a=0,int b=0):x(a),y(b){} };
struct Scalar { Scalar(double=0,double=0,double=0,double=0){} };
struct Vec3b { unsigned char v[3]{}; Vec3b()=default; Vec3b(unsigned char a,unsigned char b,unsigned char c){v[0]=a;v[1]=b;v[2]=c;} unsigned char& operator[](int i){return v[i];} const unsigned char& operator[](int i)const{return v[i];} };
class Mat {
public:
 int rows=0, cols=0; unsigned char *data=nullptr;
 Mat()=default; Mat(int r,int c,int):rows(r),cols(c){}
 static Mat zeros(int r,int c,int t){return Mat(r,c,t);} static Mat zeros(Size s,int t){return Mat(s.height,s.width,t);} bool empty()const{return false;}
 size_t total()const{return (size_t)rows*(size_t)cols;} size_t elemSize()const{return 3;}
 Size size()const{return Size(cols,rows);} Mat clone()const{return *this;} void copyTo(Mat&)const{}
 template<class T> T& at(int,int){static T x{}; return x;} template<class T> const T& at(int,int)const{static T x{}; return x;}
};
inline void resize(const Mat&,Mat&,Size){} inline void cvtColor(const Mat&,Mat&,int){}
inline void GaussianBlur(const Mat&,Mat&,Size,double,double=0){}
inline void putText(Mat&,const std::string&,Point,int,double,Scalar,int){}
inline bool imencode(const std::string&,const Mat&,std::vector<uchar>&,const std::vector<int>&){return true;}
inline Mat imread(const std::string&,int=1){return Mat(720,1280,CV_8UC3);}
class VideoCapture {
public:
 bool open(const std::string&,int){return true;} bool open(int,int){return true;} bool isOpened()const{return true;} void release(){}
 bool set(int,double){return true;} double get(int p)const{return p==CAP_PROP_FRAME_WIDTH?1280:(p==CAP_PROP_FRAME_HEIGHT?720:(p==CAP_PROP_FPS?30:1196444237));}
 VideoCapture& operator>>(Mat& m){m=Mat(720,1280,CV_8UC3);return *this;}
};
}
