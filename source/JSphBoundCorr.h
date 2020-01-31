//HEAD_DSPH
/*
 <DUALSPHYSICS>  Copyright (c) 2016, Dr Jose M. Dominguez et al. (see http://dual.sphysics.org/index.php/developers/). 

 EPHYSLAB Environmental Physics Laboratory, Universidade de Vigo, Ourense, Spain.
 School of Mechanical, Aerospace and Civil Engineering, University of Manchester, Manchester, U.K.

 This file is part of DualSPHysics. 

 DualSPHysics is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or (at your option) any later version. 

 DualSPHysics is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. 

 You should have received a copy of the GNU General Public License, along with DualSPHysics. If not, see <http://www.gnu.org/licenses/>. 
*/

//:NO_COMENTARIO
//:#############################################################################
//:# Cambios:
//:# =========
//:# - Clase para extrapolar densidad en un determinado contorno. (03-05-2017)
//:# - Simple configuration for parallel boxes of boundary particles. (13-06-2018)
//:# - Saves VTK file (CfgBoundCorr_Limit.vtk) with LimitPos and Direction 
//:#   configuration. (13-06-2018)
//:#############################################################################

/// \file JSphBoundCorr.h \brief Declares the class \ref JSphBoundCorr.

#ifndef _JSphBoundCorr_
#define _JSphBoundCorr_

#include <string>
#include <vector>
#include "JObject.h"
#include "Types.h"

class JXml;
class TiXmlElement;
class JLog2;
class JLinearValue;
class JSphMk;
class JSphPartsInit;

//##############################################################################
//# XML format in _FmtXML_BoundCorr.xml.
//##############################################################################

//##############################################################################
//# JSphBoundCorrZone
//##############################################################################
/// \brief Manages one configuration for boundary extrapolated correction.
class JSphBoundCorrZone : protected JObject
{
public:
///Direction mode.
typedef enum{ 
    DIR_None=0,
    DIR_Top=1,
    DIR_Bottom=2,
    DIR_Left=3,
    DIR_Right=4,
    DIR_Front=5,
    DIR_Back=6,
    DIR_Defined=10
}TpDirection;  

private:
  JLog2 *Log;

  //-Selection of particles
  typecode BoundCode;      ///<Code to select boundary particles.

  //-Configuration parameters.
  TpDirection AutoDir; ///<Direction configuration for automatic definition.
  double AutoDpFactor; ///<Point is calculated starting from bound particles at distance dp*AutoDpFactor.
  tdouble3 LimitPos;   ///<Limit between boundary and fluid.
  tdouble3 Direction;  ///<Direction to fluid particles.
  tplane3f Plane;      ///<Plane in limit.

  void Reset();

public:
  const unsigned IdZone;
  const word MkBound;

  JSphBoundCorrZone(JLog2 *log,unsigned idzone,word mkbound
    ,TpDirection autodir,double autodpfactor,tdouble3 limitpos,tdouble3 direction);
  ~JSphBoundCorrZone();
  void ConfigBoundCode(typecode boundcode);
  void ConfigAuto(const JSphPartsInit *partsdata);

  void RunMotion(bool simple,const tdouble3 &msimple,const tmatrix4d &mmatrix);

  void GetConfig(std::vector<std::string> &lines)const;

  TpDirection GetAutoDir()const{ return(AutoDir); }
  tdouble3 GetLimitPos()const{ return(LimitPos); }
  tdouble3 GetDirection()const{ return(Direction); }
  tplane3f GetPlane()const{ return(Plane); }
  typecode GetBoundCode()const{ return(BoundCode); }
};

//##############################################################################
//# JSphBoundCorr
//##############################################################################
/// \brief Manages configurations for boundary extrapolated correction.
class JSphBoundCorr : protected JObject
{
private:
  JLog2 *Log;
  const double Dp;

  float DetermLimit;     ///<Limit for determinant. Use 1e-3 for first_order or 1e+3 for zeroth_order (default=1e+3).
  byte ExtrapolateMode;  ///<Calculation mode for rhop extrapolation from ghost nodes 1:fast-single, 2:single, 3:double (default=1).

  std::vector<JSphBoundCorrZone*> List; ///<List of configurations.

  bool UseMotion; ///<Some boundary is moving boundary.

  void Reset();
  bool ExistMk(word mkbound)const;
  void LoadXml(JXml *sxml,const std::string &place);
  void ReadXml(const JXml *sxml,TiXmlElement* lis);
  void UpdateMkCode(const JSphMk *mkinfo);
  void SaveVtkConfig(double dp,int part)const;

public:
  const bool Cpu;

  JSphBoundCorr(bool cpu,double dp,JLog2 *log,JXml *sxml,const std::string &place,const JSphMk *mkinfo);
  ~JSphBoundCorr();

  void RunAutoConfig(const JSphPartsInit *partsdata);

  void VisuConfig(std::string txhead,std::string txfoot)const;
  unsigned GetCount()const{ return(unsigned(List.size())); };

  float GetDetermLimit()const{ return(DetermLimit); };
  byte GetExtrapolateMode()const{ return(ExtrapolateMode); };

  bool GetUseMotion()const{ return(UseMotion); }
  void RunMotion(word mkbound,bool simple,const tdouble3 &msimple,const tmatrix4d &mmatrix);

  const JSphBoundCorrZone* GetMkZone(unsigned idx)const{ return(idx<GetCount()? List[idx]: NULL); }

  void SaveData(int part)const;

};



#endif


