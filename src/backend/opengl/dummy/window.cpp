/*******************************************************
 * Copyright (c) 2015-2019, ArrayFire
 * All rights reserved.
 *
 * This file is distributed under 3-clause BSD license.
 * The complete license agreement can be obtained at:
 * http://arrayfire.com/licenses/BSD-3-Clause
 ********************************************************/

#include <common/defines.hpp>
#include <common/err_handling.hpp>
#include <gl_native_handles.hpp>
#include <dummy/window.hpp>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>  //using this for getProcAddr

#include <glm/gtc/epsilon.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>

#include <cmath>
#include <utility>

using glm::epsilonNotEqual;
using glm::make_vec4;
using glm::mat4;
using glm::rotate;
using glm::scale;
using glm::translate;
using glm::vec2;
using glm::vec3;
using glm::vec4;
using std::floor;
using std::get;
using std::make_tuple;
using std::tuple;

using namespace forge::common;

namespace forge {
namespace wtk {
static int nextwinid = 1;

void initWindowToolkit() { return; }

void destroyWindowToolkit() { return; }

tuple<vec3, vec2> getCellCoordsDims(const vec2& pos, const CellIndex& idx, const vec2& dims)
{
    const int rows = get<0>(idx);
    const int cols = get<1>(idx);
    const int cw   = dims[0] / cols;
    const int ch   = dims[1] / rows;
    const int x    = static_cast<int>(floor(pos[0] / static_cast<double>(cw)));
    const int y    = static_cast<int>(floor(pos[1] / static_cast<double>(ch)));
    return make_tuple(vec3(x * cw, y * ch, x + y * cols), vec2(cw, ch));
}

const vec4 Widget::getCellViewport(const vec2& pos)
{
    // Either of the transformation matrix maps are fine for figuring
    // out the viewport corresponding to the current mouse position
    // Here I am using mOrientMatrices map
    vec4 retVal(0, 0, mWidth, mHeight);
    for (auto& it : mOrientMatrices) {
        const CellIndex& idx = it.first;
        auto coordsAndDims = getCellCoordsDims(pos, idx, vec2(mWidth, mHeight));
        if (get<0>(coordsAndDims)[2] == std::get<2>(idx)) {
            retVal = vec4(get<0>(coordsAndDims)[0], get<0>(coordsAndDims)[1],
                          get<1>(coordsAndDims));
            break;
        }
    }
    return retVal;
}

const mat4 Widget::findTransform(const MatrixHashMap& pMap, const double pX, const double pY)
{
    for (auto it : pMap) {
        const CellIndex& idx = it.first;
        const mat4& mat      = it.second;
        auto coordsAndDims =
            getCellCoordsDims(vec2(pX, pY), idx, vec2(mWidth, mHeight));
        if (get<0>(coordsAndDims)[2] == std::get<2>(idx)) { return mat; }
    }
    return IDENTITY;
}

const mat4 Widget::getCellViewMatrix(const double pXPos, const double pYPos)
{
    return findTransform(mViewMatrices, pXPos, pYPos);
}

const mat4 Widget::getCellOrientationMatrix(const double pXPos, const double pYPos)
{
    return findTransform(mOrientMatrices, pXPos, pYPos);
}

void Widget::setTransform(MatrixHashMap& pMap, const double pX, const double pY, const mat4& pMat)
{
    for (auto it : pMap) {
        const CellIndex& idx = it.first;
        auto coordsAndDims =
            getCellCoordsDims(vec2(pX, pY), idx, vec2(mWidth, mHeight));
        if (get<0>(coordsAndDims)[2] == std::get<2>(idx)) {
            pMap[idx] = pMat;
            return;
        }
    }
}

void Widget::setCellViewMatrix(const double pXPos, const double pYPos,
                               const mat4& pMatrix) {
    return setTransform(mViewMatrices, pXPos, pYPos, pMatrix);
}

void Widget::setCellOrientationMatrix(const double pXPos, const double pYPos,
                                      const mat4& pMatrix) {
    return setTransform(mOrientMatrices, pXPos, pYPos, pMatrix);
}

void Widget::resetViewMatrices() {
    for (auto it : mViewMatrices) it.second = IDENTITY;
}

void Widget::resetOrientationMatrices() {
    for (auto it : mOrientMatrices) it.second = IDENTITY;
}

Widget::Widget()
    : mWindow(NULL)
    , mClose(false)
    , mLastPos(0, 0)
    , mButton(-1)
    , mRotationFlag(false)
    , mWidth(512)
    , mHeight(512) {}

Widget::Widget(int pWidth, int pHeight, const char* pTitle,
               const std::unique_ptr<Widget>& pWidget, const bool invisible)
    : mWindow(NULL)
    , mClose(false)
    , mLastPos(0, 0)
    , mButton(-1)
    , mRotationFlag(false) {

      mDummy = nextwinid;
      mWindow = &mDummy;
      nextwinid++;
}

Widget::~Widget() {
}

int* Widget::getNativeHandle() const { return mWindow; }

void Widget::makeContextCurrent() const { return; }

long long Widget::getGLContextHandle() {
    return opengl::getCurrentContextHandle();
}

long long Widget::getDisplayHandle() {
    return opengl::getCurrentDisplayHandle();
}

GLADloadproc Widget::getProcAddr() {
    return reinterpret_cast<GLADloadproc>(glfwGetProcAddress);
}

void Widget::setTitle(const char* pTitle) {
    return;
}

void Widget::setPos(int pX, int pY) { return; }

void Widget::setSize(unsigned pW, unsigned pH) {
    return;
}

void Widget::swapBuffers() { return; }

void Widget::hide() {
    return;
}

void Widget::show() {
    return;
}

bool Widget::close() { return mClose; }

void Widget::resetCloseFlag() {
    if (mClose == true) { show(); }
}

void Widget::resizeHandler(int pWidth, int pHeight) {
    mWidth  = pWidth;
    mHeight = pHeight;
}

void Widget::keyboardHandler(int pKey, int pScancode, int pAction, int pMods) {
    return;
}

void Widget::cursorHandler(const double pXPos, const double pYPos) {
  return;
}

void Widget::mouseButtonHandler(int pButton, int pAction, int pMods) {
  return;
}

void Widget::pollEvents() { return; }

const mat4 Widget::getViewMatrix(const CellIndex& pIndex) {
    if (mViewMatrices.find(pIndex) == mViewMatrices.end()) {
        mViewMatrices.emplace(pIndex, IDENTITY);
    }
    return mViewMatrices[pIndex];
}

const mat4 Widget::getOrientationMatrix(const CellIndex& pIndex) {
    if (mOrientMatrices.find(pIndex) == mOrientMatrices.end()) {
        mOrientMatrices.emplace(pIndex, IDENTITY);
    }
    return mOrientMatrices[pIndex];
}

glm::vec2 Widget::getCursorPos() const {
    double xp=0, yp=0;
    return {xp, yp};
}

}  // namespace wtk
}  // namespace forge
