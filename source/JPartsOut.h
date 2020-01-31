//HEAD_DSPH
/*
 <DUALSPHYSICS>  Copyright (c) 2019 by Dr Jose M. Dominguez et al. (see http://dual.sphysics.org/index.php/developers/). 

 EPHYSLAB Environmental Physics Laboratory, Universidade de Vigo, Ourense, Spain.
 School of Mechanical, Aerospace and Civil Engineering, University of Manchester, Manchester, U.K.

 This file is part of DualSPHysics. 

 DualSPHysics is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License 
 as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version.
 
 DualSPHysics is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more details. 

 You should have received a copy of the GNU Lesser General Public License along with DualSPHysics. If not, see <http://www.gnu.org/licenses/>. 
*/

//:#############################################################################
//:# Cambios:
//:# =========
//:# - Almacena temporalmente las particulas excluidas hasta que se graben en
//:#   el siguiente part. (08-11-2011)
//:# - Las funcion GetAllocMemory() devuelve long long. (05-04-2013)
//:# - Pos pasa a ser tdouble3 en lugar de tfloat3. (24-11-2013)
//:# - Se incluye el motivo de exclusion. (20-03-2018)
//:#############################################################################

/// \file JPartsOut.h \brief Declares the class \ref JPartsOut.

#ifndef _JPartsOut_
#define _JPartsOut_

#include "Types.h"
#include "JObject.h"
#include <cstring>

//##############################################################################
//# JPartsOut
//##############################################################################
/// \brief Stores excluded particles at each instant until writing the output file. 

class JPartsOut : protected JObject
{
public:

protected:
  unsigned SizeIni;
  unsigned Size;
  unsigned Count;
  
  unsigned OutPosCount,OutRhopCount,OutMoveCount;

  unsigned *Idp;
  tdouble3 *Pos;
  tfloat3 *Vel;
  float *Rhop;
  byte *Motive; ///<Motives for exclusion. 1:position, 2:rhop, 3:velocity.

  void AllocMemory(unsigned size,bool reset);

public:
  JPartsOut(unsigned sizeini=2000);
  ~JPartsOut();
  void Reset();
  llong GetAllocMemory()const;
  void AddParticles(unsigned np,const unsigned* idp,const tdouble3* pos,const tfloat3* vel,const float* rhop,const typecode* code);

  unsigned GetSize()const{ return(Size); }
  unsigned GetCount()const{ return(Count); }

  unsigned GetOutPosCount()const{ return(OutPosCount); }
  unsigned GetOutRhopCount()const{ return(OutRhopCount); }
  unsigned GetOutMoveCount()const{ return(OutMoveCount); }

  const unsigned* GetIdpOut(){ return(Idp); }
  const tdouble3* GetPosOut(){ return(Pos); }
  const tfloat3* GetVelOut(){ return(Vel); }
  const float* GetRhopOut(){ return(Rhop); }
  const byte* GetMotiveOut(){ return(Motive); }

  void Clear(){ Count=0; OutPosCount=OutRhopCount=OutMoveCount=0; };
};

#endif


